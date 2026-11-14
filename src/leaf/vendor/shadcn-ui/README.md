# shadcn/ui reference

Source: https://github.com/shadcn-ui/ui
Commit: `42f3bb63b46a69e52a24bd005cdc9ec15ba7a7b9`
Registry: `apps/v4/registry/new-york-v4/ui/`
Palette: `neutral` from `apps/v4/registry/themes.ts`

Leaf derives design-token values and native component conventions from this
MIT-licensed reference. No React, Tailwind, Radix, or JavaScript runtime is
bundled by this standard UI implementation. Not every upstream component has
been implemented; see `docs/ui/README.md`.

`LICENSE.txt` preserves upstream's exact MIT notice. `manifest.json` records
provenance for packaged license inventories.

The account-page increment references `ui/textarea.tsx`, `ui/label.tsx`, `ui/field.tsx` and `ui/card.tsx` at the same pinned commit. Native vertical Field and explicit-height multiline EDIT are bounded subsets, not the full React/Radix components.

Badge／Separator：同一固定commit的badge.tsx及separator.tsx布局／配色参考已纳入manifest SHA。
原生非交互文字Badge及视觉装饰线仅受限子集；无React/Radix运行时、asChild、
图标或完整ARIA语义。STATIC的助记符Name规范化及装饰线UIA可见性限制见docs/ui/README.md。

Empty：同一固定commit的empty.tsx布局/字号参考SHA纳manifest，仅原生文字和Button组合。
无EmptyMedia、图标、CSS断点/max-width/text-balance或富文本链接；系统可访问性限制见docs/ui。
