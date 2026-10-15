# Additional terms under GPL-3.0 section 7 / GPL-3.0 第七条附加条款

本仓库的许可证是 [LICENSE](LICENSE)（GNU General Public License version 3，**GPL-3.0-or-later**）。
本文件列出在其之上依据 GPL-3.0 **第七条(b) 与 (c)** 附加的合理条款。二者共同构成 Disynk 的完整许可条件,
缺一不可;本文件不修改、不限制 GPL-3.0 授予你的任何自由。

This repository is licensed under the GNU GPL version 3 (see [LICENSE](LICENSE)). The document below
states the additional terms appended in accord with **GPL-3.0 §7(b) and §7(c)**. Both files together
are the complete licensing conditions of Disynk; nothing here narrows any freedom GPL-3.0 grants you.

## 1. 保留源地址与来源标注 / Preserve the source location and attribution

再分发本程序(无论是否修改),必须以可查证的形式同时保留:

- 项目源地址:<https://github.com/Rhinocros/Disynk>
- 一句来源标注,说明该版本源自 Disynk 项目(例如「基于 Disynk <https://github.com/Rhinocros/Disynk> 修改」)
- `LICENSE`、本文件与 `THIRD-PARTY-NOTICES.md` 的完整文本
- 各源码文件中已有的版权与许可声明

Any copy you redistribute — modified or not — must carry, in a verifiable form: the project source
location above; a statement of origin identifying the build as derived from Disynk; the full text of
`LICENSE`, this file and `THIRD-PARTY-NOTICES.md`; and the copyright/licensing notices already present
in the source files.

## 2. 界面保留可点击链接 / Keep a clickable link in the user interface

这是 GPL-3.0 §7(b) 所允许的「要求在工作所含的适当法律通告中保留指定署名」的具体形态:

- 衍生版本的应用界面中必须保留**至少一处可点击的项目链接**(指向上述源地址),
  且不得移除、禁用或降级为不可点击的纯文本。
- Disynk 自身把它放在主窗口的「关于」分区(见 `Sources/DisynkApp/About.swift`)。
  修改版可以改样式与位置,但链接必须仍然可点、可达、指向上述源地址。

A derivative build must keep at least one **clickable** link to the project source location in its
user interface; it may not be removed, disabled, or downgraded to non-clickable text. Restyling or
relocating it is fine — being clickable and pointing at the source location above is not optional.

## 3. 修改版不可闭源 / Derivatives stay open

这一条不新增限制,只是把 GPL-3.0 本身的后果说清楚:

- 你对外提供(convey)的衍生版本,整体必须以 GPL-3.0 或其后版本授权,并随之分发或书面承诺提供
  完整对应源码(Corresponding Source)。
- 不得闭源发布,不得去除许可文本、署名或链接,不得追加 GPL 视为「进一步限制」的条款。
- 仅自己编译、不对外提供(含不提供下载、不部署供他人使用)的修改,不需要公开——这是 GPL 的既有边界。
- §7(c):修改版不得虚报来源。你可以要求外界把你的构建与上游区分开,也欢迎你在标注中说明改了什么。

Conveying a derivative means licensing the whole work under GPL-3.0-or-later and making the complete
Corresponding Source available. Closed-source distribution is not permitted, nor is removing license
text, attribution, or the link. Modifications you never convey remain private — that is GPL's own
boundary. Under §7(c) you must not misrepresent the origin of the material.

## 4. 与旧条款的关系 / Relation to the previous notice

2026-10 之前的版本附带一份专有许可声明(要求保留授权/激活机制)。该声明已随授权分发一并废弃:
本项目现在是 GPL-3.0-or-later 自由软件,不再包含任何激活码、功能门控或设备绑定逻辑,
此前的专有条款不再适用于当前源码树及其衍生版本。

Releases before 2026-10 shipped a proprietary notice tied to license activation. That notice and the
whole activation/feature-gating/HWID mechanism have been retired: this source tree is free software
under GPL-3.0-or-later, and the old proprietary terms do not apply to it or to its derivatives.
