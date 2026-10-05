## Embedded license texts make the installed packager independent of its checkout.
import std/[os, json]
const
  LeafLicense = staticRead("../../LICENSE")
  NimLicense = staticRead("vendor/Nim-LICENSE.txt")
  ZippyLicense = staticRead("vendor/zippy/LICENSE")
  ChecksumsLicense = staticRead("vendor/checksums/LICENSE")
  GpuiNotices = staticRead("vendor/GPUI-NOTICES.json")
  Provenance = staticRead("vendor/provenance.json")

proc collectLicenses*(destination: string) =
  createDir(destination / "tools")
  writeFile(destination / "Leaf-LICENSE.txt", LeafLicense)
  writeFile(destination / "Nim-LICENSE.txt", NimLicense)
  writeFile(destination / "tools/Zippy-LICENSE.txt", ZippyLicense)
  writeFile(destination / "tools/Checksums-LICENSE.txt", ChecksumsLicense)
  writeFile(destination / "GPUI-NOTICES.json", GpuiNotices)
  var inventory = parseJson(Provenance)
  inventory["leaf"] = %*{"license": "MIT", "source": "https://github.com/SatoriTours/Leaf", "license_file": "Leaf-LICENSE.txt"}
  inventory["system_dependencies"] = %*["GPUI + GPUI Kit bridge (bundled; see GPUI-NOTICES.json)",
    "System graphics drivers, fonts and platform dependencies (not bundled)"]
  writeFile(destination / "inventory.json", inventory.pretty() & "\n")
