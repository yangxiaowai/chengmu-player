# Task Plan: v0.4.2 剧集完成状态修复

## Goal
单集看完不等于整部作品完成；可靠最后一集才完成，提供安全续看下一集，保留电影与旧记录边界，构建安装并同步GitHub。

## Next Step
v0.4.2已安装并公开发行，远端附件SHA-256与本地一致，交付说明。

## Current Phase
Phase 5

## Phases

### Phase 1: Requirements & Discovery
- [x] Understand user intent
- [x] Identify constraints
- [x] Document in findings.md
- **Status:** complete

### Phase 2: Planning & Structure
- [x] Define approach
- [x] Create project structure
- **Status:** complete

### Phase 3: Implementation
- [x] Execute the plan
- [x] Write to files before executing
- **Status:** complete

### Phase 4: Testing & Verification
- [x] Verify requirements met
- [x] Document test results
- **Status:** complete

### Phase 5: Delivery
- [x] Review outputs
- [x] Deliver to user
- **Status:** complete

## Decisions Made
| Decision | Rationale |
|----------|-----------|

## Errors Encountered
| Error | Resolution |
|-------|------------|

## Scope decisions
- 以保存的同一作品/季选集上下文判断最后一集；不推测跨季，也不声称当前片源已正式完结。
- 95%仅代表单集进度完成，未知/损坏的集目不标全剧完成。
- 下一集只使用同线路的连续编号；全部剧集视图保留单集完成/重看。
- 不更改历史JSON结构，不新增网络请求。
