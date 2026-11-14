/* Minimal, project-local declarations of the UI Automation provider
 * interfaces this select needs. Only identity and ABI facts are declared here:
 * IIDs and vtable order were extracted from Microsoft-shipped binaries on the
 * acceptance VM (see docs/ui/README.md and the artifact note
 * m2-select-uia-definitions.md): UIAutomationProvider.dll / UIAutomationTypes.dll
 * 4.8.9347.0 (NET481REL1LAST_25H2_B) and UIAutomationCore.dll 7.2.26100.1.
 * No SDK was installed or copied; no other component's stock provider is
 * replaced.
 *
 * Numeric UIA ids used by select_provider.c come from the same dumps.
 */
#ifndef LEAF_SELECT_UIA_H
#define LEAF_SELECT_UIA_H

#include <windows.h>
#include <oleauto.h>
/* PROPERTYID / PATTERNID / EVENTID / enum ProviderOptions / IAccessibleEx-level
   IRawElementProviderSimple come with the toolchain header. */
#include <uiautomationcore.h>

/* NavigateDirection (System.Windows.Automation.Provider.NavigateDirection). */
enum LeafNavigateDirection {
  LeafNavigateParent = 0,
  LeafNavigateNextSibling = 1,
  LeafNavigatePreviousSibling = 2,
  LeafNavigateFirstChild = 3,
  LeafNavigateLastChild = 4
};

/* StructureChangeType (System.Windows.Automation.StructureChangeType). */
enum LeafStructureChangeType {
  LeafStructureChildAdded = 0,
  LeafStructureChildRemoved = 1,
  LeafStructureChildrenInvalidated = 2,
  LeafStructureChildrenBulkAdded = 3,
  LeafStructureChildrenBulkRemoved = 4,
  LeafStructureChildrenReordered = 5
};

/* UiaRect: layout-compatible 4-double rectangle used by fragment bounds. */
struct UiaRect { double left, top, width, height; };

/* UIA identifiers (see the artifact note for provenance). */
#define LEAF_UIA_CT_COMBOBOX 50003
#define LEAF_UIA_CT_LIST 50008
#define LEAF_UIA_CT_LISTITEM 50007
#define LEAF_UIA_P_BOUNDINGRECT 30001
#define LEAF_UIA_P_CONTROLTYPE 30003
#define LEAF_UIA_P_NAME 30005
#define LEAF_UIA_P_HASFOCUS 30008
#define LEAF_UIA_P_FOCUSABLE 30009
#define LEAF_UIA_P_ENABLED 30010
#define LEAF_UIA_P_HELPTEXT 30013
#define LEAF_UIA_P_ISCONTROL 30016
#define LEAF_UIA_P_ISCONTENT 30017
#define LEAF_UIA_P_OFFSCREEN 30022
#define LEAF_UIA_P_EXPAND_AVAILABLE 30028
#define LEAF_UIA_P_SELECTIONITEM_AVAILABLE 30036
#define LEAF_UIA_P_SELECTION_AVAILABLE 30037
#define LEAF_UIA_P_VALUE_AVAILABLE 30043
#define LEAF_UIA_P_VALUE 30045
#define LEAF_UIA_P_VALUE_READONLY 30046
#define LEAF_UIA_P_SELECTION_MULTIPLE 30060
#define LEAF_UIA_P_SELECTION_REQUIRED 30061
#define LEAF_UIA_P_EXPANDSTATE 30070
#define LEAF_UIA_P_SELECTED 30079
#define LEAF_UIA_PATTERN_SELECTION 10001
#define LEAF_UIA_PATTERN_VALUE 10002
#define LEAF_UIA_PATTERN_EXPAND 10005
#define LEAF_UIA_PATTERN_SELECTIONITEM 10010
#define LEAF_UIA_EVENT_STRUCTURE 20002
#define LEAF_UIA_EVENT_SELECTEDITEM 20012
#define LEAF_UIA_EVENT_SELECTIONINVALIDATED 20013

typedef struct LeafUiaFragment LeafUiaFragment;
typedef struct LeafUiaFragmentRoot LeafUiaFragmentRoot;
typedef struct LeafUiaExpand LeafUiaExpand;
typedef struct LeafUiaValue LeafUiaValue;
typedef struct LeafUiaSelection LeafUiaSelection;
typedef struct LeafUiaSelectionItem LeafUiaSelectionItem;

typedef struct LeafUiaFragmentVtbl LeafUiaFragmentVtbl;
struct LeafUiaFragmentVtbl {
  HRESULT (STDMETHODCALLTYPE *QueryInterface)(LeafUiaFragment*,REFIID,void**);
  ULONG (STDMETHODCALLTYPE *AddRef)(LeafUiaFragment*);
  ULONG (STDMETHODCALLTYPE *Release)(LeafUiaFragment*);
  HRESULT (STDMETHODCALLTYPE *Navigate)(LeafUiaFragment*,enum LeafNavigateDirection,LeafUiaFragment**);
  HRESULT (STDMETHODCALLTYPE *GetRuntimeId)(LeafUiaFragment*,SAFEARRAY**);
  HRESULT (STDMETHODCALLTYPE *get_BoundingRectangle)(LeafUiaFragment*,struct UiaRect*);
  HRESULT (STDMETHODCALLTYPE *GetEmbeddedFragmentRoots)(LeafUiaFragment*,SAFEARRAY**);
  HRESULT (STDMETHODCALLTYPE *SetFocus)(LeafUiaFragment*);
  HRESULT (STDMETHODCALLTYPE *get_FragmentRoot)(LeafUiaFragment*,LeafUiaFragmentRoot**);
};
struct LeafUiaFragment { const struct LeafUiaFragmentVtbl *lpVtbl; };

typedef struct LeafUiaFragmentRootVtbl LeafUiaFragmentRootVtbl;
struct LeafUiaFragmentRootVtbl {
  HRESULT (STDMETHODCALLTYPE *QueryInterface)(LeafUiaFragmentRoot*,REFIID,void**);
  ULONG (STDMETHODCALLTYPE *AddRef)(LeafUiaFragmentRoot*);
  ULONG (STDMETHODCALLTYPE *Release)(LeafUiaFragmentRoot*);
  HRESULT (STDMETHODCALLTYPE *ElementProviderFromPoint)(LeafUiaFragmentRoot*,double,double,LeafUiaFragment**);
  HRESULT (STDMETHODCALLTYPE *GetFocus)(LeafUiaFragmentRoot*,LeafUiaFragment**);
};
struct LeafUiaFragmentRoot { const struct LeafUiaFragmentRootVtbl *lpVtbl; };

typedef struct LeafUiaExpandVtbl LeafUiaExpandVtbl;
struct LeafUiaExpandVtbl {
  HRESULT (STDMETHODCALLTYPE *QueryInterface)(LeafUiaExpand*,REFIID,void**);
  ULONG (STDMETHODCALLTYPE *AddRef)(LeafUiaExpand*);
  ULONG (STDMETHODCALLTYPE *Release)(LeafUiaExpand*);
  HRESULT (STDMETHODCALLTYPE *Expand)(LeafUiaExpand*);
  HRESULT (STDMETHODCALLTYPE *Collapse)(LeafUiaExpand*);
  HRESULT (STDMETHODCALLTYPE *get_ExpandCollapseState)(LeafUiaExpand*,int*);
};
struct LeafUiaExpand { const struct LeafUiaExpandVtbl *lpVtbl; };

typedef struct LeafUiaValueVtbl LeafUiaValueVtbl;
struct LeafUiaValueVtbl {
  HRESULT (STDMETHODCALLTYPE *QueryInterface)(LeafUiaValue*,REFIID,void**);
  ULONG (STDMETHODCALLTYPE *AddRef)(LeafUiaValue*);
  ULONG (STDMETHODCALLTYPE *Release)(LeafUiaValue*);
  HRESULT (STDMETHODCALLTYPE *SetValue)(LeafUiaValue*,LPCWSTR);
  HRESULT (STDMETHODCALLTYPE *get_Value)(LeafUiaValue*,BSTR*);
  HRESULT (STDMETHODCALLTYPE *get_IsReadOnly)(LeafUiaValue*,BOOL*);
};
struct LeafUiaValue { const struct LeafUiaValueVtbl *lpVtbl; };

typedef struct LeafUiaSelectionVtbl LeafUiaSelectionVtbl;
struct LeafUiaSelectionVtbl {
  HRESULT (STDMETHODCALLTYPE *QueryInterface)(LeafUiaSelection*,REFIID,void**);
  ULONG (STDMETHODCALLTYPE *AddRef)(LeafUiaSelection*);
  ULONG (STDMETHODCALLTYPE *Release)(LeafUiaSelection*);
  HRESULT (STDMETHODCALLTYPE *GetSelection)(LeafUiaSelection*,SAFEARRAY**);
  HRESULT (STDMETHODCALLTYPE *get_CanSelectMultiple)(LeafUiaSelection*,BOOL*);
  HRESULT (STDMETHODCALLTYPE *get_IsSelectionRequired)(LeafUiaSelection*,BOOL*);
};
struct LeafUiaSelection { const struct LeafUiaSelectionVtbl *lpVtbl; };

typedef struct LeafUiaSelectionItemVtbl LeafUiaSelectionItemVtbl;
struct LeafUiaSelectionItemVtbl {
  HRESULT (STDMETHODCALLTYPE *QueryInterface)(LeafUiaSelectionItem*,REFIID,void**);
  ULONG (STDMETHODCALLTYPE *AddRef)(LeafUiaSelectionItem*);
  ULONG (STDMETHODCALLTYPE *Release)(LeafUiaSelectionItem*);
  HRESULT (STDMETHODCALLTYPE *Select)(LeafUiaSelectionItem*);
  HRESULT (STDMETHODCALLTYPE *AddToSelection)(LeafUiaSelectionItem*);
  HRESULT (STDMETHODCALLTYPE *RemoveFromSelection)(LeafUiaSelectionItem*);
  HRESULT (STDMETHODCALLTYPE *get_IsSelected)(LeafUiaSelectionItem*,BOOL*);
  HRESULT (STDMETHODCALLTYPE *get_SelectionContainer)(LeafUiaSelectionItem*,LeafUiaFragment**);
};
struct LeafUiaSelectionItem { const struct LeafUiaSelectionItemVtbl *lpVtbl; };

#endif
