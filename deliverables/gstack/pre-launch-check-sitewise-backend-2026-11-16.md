# SiteWise 上线前全检报告（代码审查 + 安全审计 + QA 测试 + 端点盘点）

**日期**：2026-11-16
**场景**：上线前检查（Pre-launch Check）
**参与成员**：调查员（gstack-investigator）+ 产品官（gstack-product-reviewer）+ 安全卫士（gstack-security-officer）+ 质量门神（gstack-qa-lead）

---

## 📌 TL;DR（执行摘要）

- 整体结论：🔴 **NO-GO（有条件）** —— 应用层代码质量高，但 1 个密钥泄露 + 27 个测试失败 + 2 个 Supabase 环境阻塞项未解决
- 阻塞项数量：**4**（密钥入库、无鉴权端点、PU 域 27 个测试失败、Supabase 注册链路 P0001/SMTP 500）
- 端点盘点结论：QG=0 个端点、QJ=1 个（仅上下文）、BCJ=3 个（持久化）；**研究报告端点未建，需新建 3-4 个**
- 下一步：轮换密钥 + 修 6 个无鉴权端点 + 收敛 PU 域测试 + 解决 Supabase 配置，然后复跑 QA

---

## 🎯 核心结论卡片

| 项目 | 内容 |
|------|------|
| Go / No-Go | 🔴 No-Go（条件性：单域失败 + 密钥泄露，修复路径明确） |
| 严重度分布 | 🔴 1 / 🟠 4 / 🟡 5 / 🟢 P2 若干 |
| 关键行动项 | 9 条（见行动清单） |
| 建议负责人 | 工程负责人 + 1 名后端协作者，预计 1-2 个工作日翻绿 |

---

## 1. 各成员核心结论

### 🔍 调查员（端点盘点）
- 核心判断：全部路由挂载在 `/api/v1` 前缀（main.py:138）。**没有任何端点执行 live LLM**：QG 零端点（`ResearchWorkflow` 从未实例化）；QJ 仅 1 个上下文交接端点 `GET /m2/research-objectives/{id}/qj-context`；BCJ 3 个持久化端点正常工作。所有 handoff 标志 `Literal[False]` / `NOT_VERIFIED` 硬锁。`/m2`、`/project1-workflow`、`/project1` 三个路由器默认禁用（config.py 开关全 False）；`/cq` 14 个端点全部 503 PRODUCTION_FIELDING_HOLD（withdraw 例外）。
- 关键建议：研究报告链路需新建 **3 个**端点（`GET /m2/assessments/{id}/report/status`、`POST .../report-admission`、`GET .../report`；若保留独立 release 则 **4 个**，现有权限模型 `report_release` 已暗示需要）。删除 4 个 `.bak` 文件。

### 🔍 产品官（代码审查）
- 核心判断：**代码健康度 GOOD，无新增 P0 缺陷**。M2/CQ 管线纪律性强（行锁、乐观版本、幂等、digest 校验、fail-closed）；QG/QJ 门禁确认运行时真实生效（三层防御：无组合点 + TokenHarbor 未配置 + 路由器未挂载），不仅靠类型标注。
- 关键建议：修 2 个 P1 —— 评估创建 check-then-insert 竞态返回 500（assessment_service.py:595-625，catch IntegrityError 后复查询）；QG 措辞门禁子串匹配可绕过（research.py:51-59，改 `\b` 词边界正则）。补一份具名 LLM 启用 runbook + 启动时断言。

### 🛡️ 安全卫士（OWASP + STRIDE 审计）
- 核心判断：应用层 auth/authz 设计属 FYP 前十百分比水平（ES256-only JWT 本地验证、角色只读本地 DB、staff 全线 aal2、CQ 会话无跨参与者路径、withdraw 永不被 hold 困住）。但**仓库卫生拖后腿**，总体评分 C+。
- 关键建议：F-01 `backend/.env`（含 Supabase service-role key + 2 个 Google Maps key + CARTO key）被 git 追踪 —— 🔴 立即轮换所有密钥再清 git；F-03 6 个无鉴权读端点（geospatial.py:31-52、statistics.py 全部）补 `CurrentUser`；F-04 昂贵端点无限流（/validate-address 每次调用烧 Google Maps 计费、SHAP 冷启 13-35s）。

### ✅ 质量门神（QA 测试）
- 核心判断：**826/884 通过（27 失败 + 31 跳过）**，另有 1 个测试文件收集错误。app 导入冒烟干净（132 paths / 148 operations）。全部失败集中在 **PU/推荐/解释域**（fnb_category v2 + expanded64 重构进行中），auth/assessment/questionnaire/reports 套件全绿。
- 关键建议：真实代码 bug 1 个（property_insights_service.py:813 lambda arity TypeError）；PU variant 默认值翻转后测试断言未同步（assert 'expanded64' == 'legacy'）；stale 测试 1 个（test_fnb_category_model.py 导入已删除符号）。收敛后复跑可翻绿。

---

## 2. 综合审查发现（去重合并，按严重度排序）

| # | 严重度 | 类别 | 位置 | 问题描述 | 建议 | 来源成员 |
|---|--------|------|------|---------|------|---------|
| 1 | 🔴 | 安全/A02 | backend/.env（git 追踪） | Supabase service-role key + Google Maps/CARTO key 泄露进仓库 | 先轮换全部密钥 → git rm --cached + .gitignore → BFG 清历史 | 安全卫士 |
| 2 | 🟠 | 安全/A01 | geospatial.py:31-52、statistics.py | 6 个无鉴权读端点，违背"全线 bearer"策略 | 加 CurrentUser 依赖（5 分钟） | 安全卫士 |
| 3 | 🟠 | 安全/A04 | recommendations.py:84、personalised_recommendations.py:108、properties.py:707、ml/* | 昂贵端点无限流；validate-address 每次烧 Google Maps 计费 | slowapi/边缘层按用户限流 | 安全卫士 |
| 4 | 🟠 | 测试 | property_insights_service.py:813 等 | PU 域 27 个测试失败 + 1 收集错误，含真实 lambda arity bug | 修 lambda；同步 expanded64 测试断言；删 stale fnb 测试 | 质量门神 |
| 5 | 🟠 | 环境 | Supabase | admin create-user P0001 + signup SMTP 500，新用户无法注册 | 解决 Supabase 配置后验证注册链路 | 质量门神 |
| 6 | 🟠 | 安全/A05 | docker-compose.yml、config.py | DB 弱口令 postgres:123456 且 5432 发布到宿主机 | 部署形态确认；移除 ports 映射、强口令 | 安全卫士 |
| 7 | 🟡 | 代码 | assessment_service.py:595-625 | 评估创建竞态 → 双开工作区返回 500 | catch IntegrityError → 复查询返回已存在 | 产品官 |
| 8 | 🟡 | 代码 | project1/research.py:51-59 | QG 措辞门禁子串匹配可绕过（"500 sqft" ⊂ "2500 sqft"） | 词边界正则 | 产品官 |
| 9 | 🟡 | 安全/A05 | photo_storage.py:41-64 等 | 上传仅扩展名+声明类型校验，无 magic-byte 嗅探 | python-magic 纵深防御 | 安全卫士 |
| 10 | 🟡 | 安全/A03 | recommendation_search_service.py:1113 等 | f-string 标识符插值 SQL（当前均为内部字面量） | 排序字段显式白名单 | 安全卫士 |
| 11 | 🟡 | 架构 | router.py:105-118、provider.py | LLM 启用路径全靠"无调用者"隐性保障；Literal[False] 启用是 schema-breaking | 启用 runbook + 启动时断言 | 产品官 |
| 12 | 🟢 | 卫生 | 4 个 .bak 文件、m2.py 重复 import | 死代码混淆检索 | 上线前删除 | 产品官/调查员 |
| 13 | 🟢 | 代码 | recommendations.py:226-267 | /recommendations/me 无分页；POST 接受客户端全量 score 字段 | limit 上限 + 服务端校验 | 产品官 |

**明确无问题（已验证）**：CQ 会话无跨参与者读写路径；withdraw 绕过 fielding hold（合规正确）；staff 全线 aal2；SQL 参数化无注入；上传 UUID 路径无遍历；LLM runner 不记录 body/凭据、禁重定向；suitability_score 措辞纪律一致。

---

## ✅ 行动清单

| # | 行动 | 负责方 | 紧急度 | 期望完成 |
|---|------|--------|--------|---------|
| 1 | 轮换 Supabase service-role key + 2 个 Google Maps key + CARTO key，然后 git rm --cached backend/.env + .gitignore + BFG 清历史 | 工程负责人 | **P0** | 立即 |
| 2 | geospatial.py 4 个 + statistics.py 2 个路由加 CurrentUser 依赖 | 后端 | **P0** | 今天 |
| 3 | 修 property_insights_service.py:813 lambda arity；同步 test_pu47 expanded64 断言；处理 test_fnb_category_model 收集错误 | 后端 | **P0** | 今天 |
| 4 | 解决 Supabase admin P0001 + signup SMTP 500，端到端验证注册 | 工程负责人 | **P0** | 上线前 |
| 5 | /validate-address、/personalised/generate、/ml/* 加限流 | 后端 | P1 | 上线前 |
| 6 | 评估创建竞态 catch IntegrityError；QG 词边界正则 | 后端 | P1 | 上线前 |
| 7 | 确认部署拓扑：docker-compose 是否生产形态；DB 端口/口令收敛 | 工程负责人 | P1 | 上线前 |
| 8 | 删除 4 个 .bak + 清理 backend/backups、bye.txt 的 git 追踪 | 后端 | P2 | 复跑 QA 前 |
| 9 | 全部修复后复跑 `pytest tests`（backend/.venv，unset 代理）确认 884 全绿 → Go | 质量门神 | P0 | 上线前 |

**研究报告端点新建计划（回答用户问题）**：需新建 **3 个**（推荐 +1 个 release 共 4 个）：
1. `GET /api/v1/m2/assessments/{id}/report/status` — 暴露 report_admission/report_release 状态
2. `POST /api/v1/m2/assessments/{id}/report-admission` — 授权把已确认上下文+候选题库准入报告管线（解锁 NOT_VERIFIED）
3. `GET /api/v1/m2/assessments/{id}/report` — 研究报告本体（confirmed review + BCB + candidates + findings 汇编）
4. （可选）`POST /api/v1/m2/assessments/{id}/report/release` — 独立签发/披露步骤

---

## ⚠️ 待完善 / 已知局限

- QA 结果反映 ~23:55 时代码树状态；仓库有并行会话在编辑（fnb_category v2 / expanded64 重构进行中），修复后必须复跑。
- 安全审计为纯静态分析，未做动态渗透；限流效果需部署后在边缘层验证。
- 前端（fyp_jaspr_web tool 链）未跑测试（需网络安装，时间盒外）。
- `/m2` 等条件路由默认禁用属于**设计决策**（fail-closed），非缺陷；启用需按 runbook 走独立发布门。

---

## 📚 成员产出索引

- gstack-investigator（调查员）：端点全量盘点（150+ 路由）、QG/QJ/BCJ 状态、报告端点缺口分析（本报告第 1 节 + 行动清单 9）
- gstack-product-reviewer（产品官）：P1×3 / P2×8 + "已做对的十件事"清单（m2/m2_business_context/research.py/services 全量审查）
- gstack-security-officer（安全卫士）：STRIDE 六维 + OWASP F-01~F-09（含静态验证的行号证据）
- gstack-qa-lead（质量门神）：pytest 全量 884 收集 / 826 过 / 27 失败明细 + 3 个失败簇根因 + app 导入冒烟（132 paths / 148 ops）

---

> 本报告由软件工坊 AI 协作生成，关键决策请由工程负责人复核。
