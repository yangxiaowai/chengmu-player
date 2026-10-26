# Findings

- WatchRecord.isCompleted只判断position/duration>=95%；AppModel.historyRecords先聚合latest再直接过滤，HistoryView同样用它显示已看完并从0重播，导致中间集完成后整部作品从继续观看消失。
- 历史已持久化MediaDetail、lineID、episodeID，playbackContext核验ID、URL与集名，可直接作为可靠边界，无需添加网络读取。
- SourceService已对episodes排序；当前播放的自动连播已有编号缺集拦截。续看历史入口需要沿用这一原则。
- 当前最新版v0.4.1/build24；本轮起点29755fd，工作区干净。
