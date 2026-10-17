# 上游来源与改进归属

## 原项目

| 项目 | 内容 |
| --- | --- |
| 原项目 | [wuruoye / TokenBar](https://github.com/wuruoye/TokenBar) |
| 原作者 | [wuruoye](https://github.com/wuruoye) |
| 本分支基点 | [`e1b743466705a497a19149c9af5a7f465e47e902`](https://github.com/wuruoye/TokenBar/commit/e1b743466705a497a19149c9af5a7f465e47e902) |
| 原许可证 | MIT，版权声明为 `Copyright (c) 2026 wuruoye` |
| 衍生维护 | [WZXsea / TokenBar-Plus](https://github.com/WZXsea/TokenBar-Plus) |

本仓库基于原项目改进，保留原项目的代码历史、[MIT 许可与版权声明](../LICENSE)及[第三方依赖说明](../THIRD_PARTY_NOTICES.md)。基点版本的原 README 完整保存在 [README.upstream.md](../README.upstream.md)，方便查阅原有功能、设计及构建说明。

## 改进范围

TokenBar 原有的 Swift/AppKit/SwiftUI 菜单栏应用、Rust 活动解析器、平台额度访问、多层会话统计、同步框架和其他平台代码构成本版本的基础。TokenBar Plus 在此基础上开展以下调整：

1. 中文界面与紧凑布局，区块显隐、顺序和菜单栏指标自定义。
2. 速度主面板、模型筛选、平滑曲线、坐标轴及采样展示。
3. 周／月／年记录切换、按需本机年度历史扫描和日期标注优化。
4. 自定义模型价格、秒级刷新选项及额外重置的展开显示。
5. 额度按日观测展示、重置以来汇总，以及额度周期漂移的恢复处理。
6. 最近会话数量限制、单行列表和“更多会话”子菜单。
7. 请求提示词、输出解析与详情加载重试改进。
8. 服务端套餐类型识别、PRO／PLUS 徽标，以及菜单栏速率的活跃和低速颜色状态。
9. 活跃与静止状态的自适应刷新、会话文件事件唤醒、会话列表局部更新，以及价格目录和历史查询的缓存管理优化。

以上为本分支的修改范围说明；具体实现与后续变化以 Git 提交和代码为准。仓库中的原图标、上游文档及原有平台代码延续其来源归属。新增 README 展示图片由程序生成示例数据渲染。

## 许可与命名

MIT 许可证允许在保留版权与许可声明的条件下修改、分发软件。本仓库沿用该许可证；第三方组件按各自许可分发，明细见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

“TokenBar Plus”用于区分此独立衍生版本与上游。原作者的贡献归属保留在许可证、Git 历史和文档中。涉及 OpenAI、Anthropic、xAI、Google 等平台的名称用于描述兼容性。
