# EE-01 证据解释端点（候选版）交付报告

**日期**：2026-11-16
**场景**：完整功能交付（设计评审 → 实现 → 安全审计 → QA 验证）
**参与成员**：产品官（gstack-product-reviewer）+ 安全卫士（gstack-security-officer）+ 质量门神（gstack-qa-lead）
**主理人**：沽思航（Gu）· 软件工坊 CEO

---

## 📌 TL;DR（执行摘要）

- 整体结论：🟢 **GO（限定于本端点）** —— 新端点实现完成、25/25 测试通过、安全审计无 P0/P1/P2、无新增回归
- 关键限定：V1.0 **刻意不调用 LLM** —— EE-01 当前 `findings=[]`（零授权 claim），按用户 prompt §8 在本地生成 `insufficient_evidence=true` 候选；prompt 与严格契约已注册，待授权适配器就绪后再接 runner
- 阻塞项数量：**0**（本端点自身）；项目级上线阻塞项见早前的上线前全检报告
- 下一步：如需真正生成解释，需先完成 EE-01 claim 授权适配器 + 生产 disclosure adapter + `project1_ai` EXPLANATION stage 迁移 + 启用 flag

---

## 🎯 核心结论卡片

| 项目 | 内容 |
|------|------|
| Go / No-Go | 🟢 Go（本端点；candidate-only 范围内） |
| 严重度分布 | 🔴 0 / 🟠 0 / 🟡 0（3 项潜伏风险已加固）/ 🟢 1（文档路径提示） |
| 新增测试 | 25 passed（含 7 类输出守卫 + Unicode/科学计数法绕过 + 无派发不变量） |
| 回归 | 147 passed / 1 skipped（直接相关套件）；全量 872 passed / 28 failed（均为既有 PU 域漂移） |
| 安全 | GO —— 跨租户 RLS 隔离、无 HTTP→LLM 路径、无数据泄漏、无 admission 写入 |
| 建议负责人 | 后端负责人（启用前置项）/ 工程负责人（治理门禁） |

---

## 1. 各成员核心结论

### 🔍 产品官（设计评审）
- 核心判断：**CONDITIONAL GO**，给出 5 项关键纠正。`report_readback()` 返回的键是 `context` 而非 `context_json`（ee01_service.py:219-220）；零授权 claim + 缺失的两个适配器（无生产 disclosure adapter、无 `project1_ai.runs` 行）使真实 LLM 调用既不安全也不可能。
- 关键建议：V1.0 **本地短路**（不调用 runner）；不扩展 `_store_held_context`（会分叉 context hash 格式）；ledger 的 stage allowlist 受 DB CHECK 约束（`('BDJ','QJ','QG')`），需新迁移，**延后**；路由无条件挂载 + 请求时 503 门（避免 404 契约破坏）；补 echo-back / 数字 / 归一化禁用短语守卫，权限标记放在 12/13 字段契约之外。

### 🛡️ 安全卫士（OWASP + STRIDE）
- 核心判断：**GO**，无 P0/P1/P2。跨租户隔离在 DB 层成立：`p1_ee01_runtime` + FORCE RLS + `owner_user_id=actor`，猜 UUID 在 `_read` 阶段 404，早于 hash/claim 校验；确认无 HTTP→`PROMPTS['EXPLANATION']`→provider 路径；候选信封仅固定字符串 + 全 false 权限标记，无原始数据泄漏；调用链纯读，无 report/admission 写入。
- 关键建议：3 项潜伏项 —— S-1 Unicode/同源词绕过禁用短语、S-2 科学计数法/千分位/数量词绕过数字守卫、S-3 未来 runner 接线风险。**均已在本轮加固**（见下）。S-4 路由遮蔽经修复后复审确认解决。

### ✅ 质量门神（QA 验证）
- 核心判断：**GO**。新测试 25/25；`tests/project1/` 137 passed / 1 skipped / 7 subtests；`test_app.py` + `test_assessment_explanation_read.py` 10 passed；`tests/cq_runtime/` 1 skipped（env-gated）；全量 872 passed / 28 failed / 31 skipped / 23 subtests，0 errors。28 个失败全部是既有 PU/recommendation 域（lambda arity 漂移 13×、variant 断言、artifact 断言），无一处提及本次改动。
- 关键建议：文档/消费者须使用 `/api/v1/cq/explanations/availability`（不是 `/cq/availability`，那是既有路由）；27→28 的 +1 为同域数据态断言，非本端点回归。

---

## 2. 交付清单

### 代码变更（6 个文件）

| 文件 | 类型 | 说明 |
|------|------|------|
| `backend/src/sitewise/project1/prompts.py` | 编辑 | 新增 `EXPLANATION` prompt，版本 `EE01-EXPLANATION-1-CAND`，完整承载用户 V1.0 规范（证据保真、数字不可变、6 条禁用措辞、§8 insufficient 规则、13 字段输出契约）；现有 `Prompt.messages()` 反注入护栏未改 |
| `backend/src/sitewise/project1/explanation_contracts.py` | 新增 | 13 字段 `ExplanationOutput` StrictModel；`insufficient_evidence_output()` 确定性构造器；`validate_candidate()` 守卫：echo-back、claim 子集/去重、Unicode NFKD+同源词归一化的禁用短语、独立数字（含科学计数法/千分位）、数量词、引用域子集 |
| `backend/src/sitewise/services/ee01_explanation_service.py` | 新增 | 读取 EE-01 held readback → 校验 context_hash/status/authority → 用服务端持有的 metadata 组装 packet → 本地生成 insufficient 候选 → 严格校验 → 返回 `no_authority()` 全 false 信封 + `llm_execution: NOT_ATTEMPTED`。**无 LLM 调用、无持久化写入** |
| `backend/src/sitewise/api/v1/ee01_explanation.py` | 新增 | 无条件挂载于 `/cq`（hold 可见）；请求时 flag 门（默认 False → 503 `EXPLANATION_MODULE_HOLD`）；`require_entrepreneur`；`Cache-Control: no-store`；CqRefused → 固定码 HTTPException |
| `backend/src/sitewise/core/config.py` | 编辑 | 新增 `ee01_explanation_enabled: bool = False`（ee01_database_url 附近） |
| `backend/src/sitewise/api/v1/router.py` | 编辑 | 无条件 include 新路由于 `/cq` 前缀 |

### 新增端点（2 个）

- `GET /api/v1/cq/explanations/availability` —— 静态 held 状态（require_entrepreneur，no-store）
- `POST /api/v1/cq/assessments/{assessment_id}/campaigns/{campaign_id}/measurements/{snapshot_id}/explanations` —— 候选解释生成请求（body: task_mode / claim_ids / context_hash，extra='forbid'）

### 测试覆盖（`tests/api/test_ee01_explanation.py`，25 项）

flag-off 503、availability held、context_hash 不匹配 409、未授权 claim 409、admission 状态变更 503、确定性 insufficient 候选（含权限标记/字段/引用）、双 task_mode 短路、13 字段契约、prompt 版本与反注入、7 类输出守卫参数化、Unicode 同源词禁用短语句式、科学计数法/千分位数字绕过、数量词 invention、**无 HTTP→LLM 派发不变量**。

### 发布检查清单

- [x] 导入与 OpenAPI 生成干净（139 paths，无 duplicate operation-id 警告）
- [x] 路由遮蔽修复：`/explanations/availability` 与既有 `/cq/availability` 共存且均 200
- [x] 全量应用集成：flag off → 503 + no-store；availability → 200 + no-store
- [x] 25 项新测试 + 147 项直接回归全绿
- [x] 安全审计 GO（跨租户 RLS、无泄漏、无写入、无 LLM 路径）
- [x] 3 项潜伏守卫风险加固 + 回归测试
- [ ] 若要启用真实 LLM 生成（**非本次范围**）：EE-01 claim 授权适配器 → 生产 disclosure adapter → `project1_ai` stage 迁移 → flag 启用 → 启用后安全复审 + 测试

### 回滚预案

新路由默认 flag=False，生产行为仅为两个 held 端点的 503/静态响应；如需回滚，删除 `router.py` 中的 include 行与 `config.py` 的 flag 即可，其他模块不受影响。无数据库迁移、无数据写入，回滚无状态残留。

---

## 3. 综合发现与处置（去重后）

| # | 严重度 | 类别 | 位置 | 问题 | 处置 |
|---|--------|------|------|------|------|
| 1 | 🟡→🟢 | 安全 | explanation_contracts.py normalise() | Unicode diacritic/fullwidth/homoglyph 绕过禁用短语 | NFKD + 组合字符剥离 + 同源词映射 + 3 项测试，已关闭 |
| 2 | 🟡→🟢 | 安全 | explanation_contracts.py `_NUMBER_RE` | 科学计数法/千分位/数量词绕过数字守卫 | 扩展正则 + 数量词守卫 + 4 项测试，已关闭 |
| 3 | 🟡→🟢 | 治理 | prompts.py EXPLANATION + provider.py | 未来 `runner('EXPLANATION',...)` 接线 + flag 翻转会派发 LLM | 新增"无派发路径"源码断言测试；flag + ledger/disclosure 必须保持强制，已关闭 |
| 4 | 🟢 | 文档 | availability 路径 | 消费者可能引用旧 `/cq/availability` | 交付说明中使用 `/explanations/availability` |
| 5 | ⚪ | 非本端点 | PU 域 28 failed | 既有 lambda arity/variant/artifact 断言漂移 | 不在本次范围；见早前上线前全检报告 |

---

## ✅ 行动清单

| # | 行动 | 负责方 | 紧急度 | 期望完成 |
|---|------|--------|--------|---------|
| 1 | 前端/文档使用 `GET /api/v1/cq/explanations/availability` 查询 held 状态 | 前端 | P2 | 集成时 |
| 2 | 若需真实 LLM：先完成 EE-01 claim 授权适配器 + 生产 disclosure adapter（`ModelRunner.require_current` 的服务器实现） | 后端 + 科学治理 | P0（启用前） | 启用前 |
| 3 | 若需真实 LLM：新增 `project1_ai` migration 扩展 stage CHECK 至含 EXPLANATION + schema_version bump | 后端 | P0（启用前） | 启用前 |
| 4 | 启用后重跑安全审计（重点 S-3 派发路径）+ 全量 QA | 安全 + QA | P0（启用前） | 启用前 |

---

## ⚠️ 待完善 / 已知局限

- V1.0 输出恒为 insufficient-evidence 候选，不产生任何解释性文本 —— 这是按用户"candidate-only + 保留 holds"选择与 prompt §8 的**刻意设计**，不是缺陷。
- 数字守卫仅覆盖阿拉伯数字（含科学计数法/千分位）与英文数量词；罗马数字/其他语言数量词未覆盖（当前无授权 claim，不可触达）。
- 全量 QA 的 28 个失败属既有 PU 域技术债（27→28 的 +1 为数据态断言，非本端点回归）；本项目整体上线仍为 🔴 NO-GO，见上线前全检报告。

---

## 📚 成员产出索引

- gstack-product-reviewer（产品官）：CONDITIONAL GO 设计评审（5 项纠正：context 键名、本地短路、held context 不扩展、ledger CHECK 延后、守卫补齐）
- gstack-security-officer（安全卫士）：GO 安全审计（STRIDE/OWASP 全覆盖；S-1~S-4；跨租户 RLS 与无 LLM 路径主动验证；修复后复审）
- gstack-qa-lead（质量门神）：GO QA（25/25 新测试、147 直接回归、872/28/31 全量基线、OpenAPI 路径与 no-store 集成验证）

---

> 本报告由软件工坊 AI 协作生成，关键决策请由工程负责人复核。
