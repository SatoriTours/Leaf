## Reuse the exact eight Native contracts, then capture a bounded visual scene
## from the real navigation HWNDs. Bitmap capture belongs only to this probe.
include ./test_win32_component_navigation
import std/[os, json]

{.passL: "-luser32 -lgdi32".}
{.emit: """
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
static int leaf_nav_capture(HWND window, const char *path) {
  RECT r; HDC source=NULL, memory=NULL; HBITMAP bitmap=NULL;
  HGDIOBJ previous=NULL; unsigned char *pixels=NULL; FILE *file=NULL;
  int ok=0, width, height; size_t bytes;
  BITMAPINFO info={0}; BITMAPFILEHEADER header={0};
  if (!GetClientRect(window,&r)) goto done;
  width=r.right-r.left; height=r.bottom-r.top;
  if (width<=0 || height<=0 || width>4096 || height>4096) goto done;
  bytes=(size_t)width*(size_t)height*4;
  if (!RedrawWindow(window,NULL,NULL,RDW_INVALIDATE|RDW_UPDATENOW|RDW_ALLCHILDREN)) goto done;
  source=GetDC(window); if (!source) goto done;
  memory=CreateCompatibleDC(source); if (!memory) goto done;
  bitmap=CreateCompatibleBitmap(source,width,height); if (!bitmap) goto done;
  previous=SelectObject(memory,bitmap); if (!previous || previous==HGDI_ERROR) goto done;
  if (!PrintWindow(window,memory,PW_CLIENTONLY)) goto done;
  if (!SelectObject(memory,previous)) goto done; previous=NULL;
  pixels=(unsigned char*)malloc(bytes); if (!pixels) goto done;
  info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth=width; info.bmiHeader.biHeight=-height;
  info.bmiHeader.biPlanes=1; info.bmiHeader.biBitCount=32;
  info.bmiHeader.biCompression=BI_RGB;
  if (GetDIBits(memory,bitmap,0,(UINT)height,pixels,&info,DIB_RGB_COLORS)!=(int)height) goto done;
  header.bfType=0x4d42; header.bfOffBits=sizeof(header)+sizeof(info.bmiHeader);
  header.bfSize=header.bfOffBits+(DWORD)bytes;
  file=fopen(path,"wb"); if (!file) goto done;
  if (fwrite(&header,sizeof(header),1,file)!=1 ||
      fwrite(&info.bmiHeader,sizeof(info.bmiHeader),1,file)!=1 ||
      fwrite(pixels,bytes,1,file)!=1) goto done;
  ok=1;
done:
  if (file && fclose(file)!=0) ok=0;
  if (previous && memory) SelectObject(memory,previous);
  if (bitmap) DeleteObject(bitmap);
  if (memory) DeleteDC(memory);
  if (source) ReleaseDC(window,source);
  free(pixels); return ok;
}
""".}
proc capture(window: HWND, path: cstring): cint {.importc: "leaf_nav_capture", nodecl.}

proc visualMain() =
  let output = getEnv("LEAF_NAV_VISUAL_DIR")
  doAssert output.len > 0
  let f = mounted()
  defer: f.h.destroyHost()
  var records = newJArray()
  proc snapshot(name, expected: string) =
    doAssert findText(f.h.windowHandle, expected) != nil
    doAssert findText(f.h.windowHandle, "depth=" & $f.model.router.history.len) != nil
    var windowRect: RECT
    doAssert GetClientRect(f.h.windowHandle, addr windowRect) != 0
    var controls = newJArray()
    for window in descendants(f.h.windowHandle):
      var bounds: RECT
      doAssert GetWindowRect(window, addr bounds) != 0
      controls.add(%*{"text": nativeText(window), "hwnd": cast[uint](window),
        "left": bounds.left, "top": bounds.top, "right": bounds.right,
        "bottom": bounds.bottom})
    doAssert capture(f.h.windowHandle, (output / (name & ".bmp")).cstring) == 1
    records.add(%*{"stage": name, "depth": f.model.router.history.len,
      "revision": f.runtime.acceptedRevision, "navigation": $f.nav().navigation,
      "hwnd": cast[uint](f.h.windowHandle), "width": windowRect.right,
      "height": windowRect.bottom, "controls": controls})
  runTurn(f, proc() =
    discard f.model.state[0].set(9)
    doAssert f.runtime.flush()
    snapshot("home", "首页 中文😀 状态=9")
    f.push("detail")
    snapshot("detail", "详情 中文😀 状态=0")
    altLeft(f.h.windowHandle)
    f.win.safeListTurn()
    doAssert f.model.router.history.len == 1
    snapshot("back", "首页 中文😀 状态=9"))
  writeFile(output / "visual.json", pretty(%*{"stages": records,
    "disposals": f.model.disposed, "status": "passed"}) & "\n")
  echo "Win32 navigation visual probe: passed"

when isMainModule: visualMain()
