import Foundation
import CinemaCore
@main struct DiagnoseSources {
 static func emit(_ object: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
  FileHandle.standardOutput.write(data + Data("\n".utf8))
 }
 static func main() async {
  for (name, route) in [("system", SourceRequestRouting.system), ("withoutHTTPProxy", .withoutHTTPProxy)] {
   let service = SourceService(routing: route)
   let start = Date()
   let results = await service.searchPages(query: "怪奇物语第一季", providers: SourceProvider.defaults)
   for result in results {
    emit(["route":name,"stage":"search","provider":result.providerID,"elapsed":Date().timeIntervalSince(start),"count":result.page?.titles.count ?? 0,"error":result.error ?? ""])
   }
   for id in ["ffzy", "dytt", "mdzy"] {
    guard let page = results.first(where: {$0.providerID == id})?.page,
          let title = page.titles.first(where: {$0.title == "怪奇物语第一季"}),
          let provider = SourceProvider.defaults.first(where: {$0.id == id}) else { continue }
    let begin = Date()
    do {
     let detail = try await service.detail(title: title, provider: provider)
     emit(["route":name,"stage":"detail","provider":id,"elapsed":Date().timeIntervalSince(begin),"lines":detail.lines.count,"episodes":detail.lines.first?.episodes.count ?? 0])
     if let url = detail.lines.first?.episodes.first?.url {
      let hlsStart = Date()
      do {
       let info = try await HLSProbe(routing:route).inspect(url:url)
       emit(["route":name,"stage":"hls","provider":id,"elapsed":Date().timeIntervalSince(hlsStart),"segments":info.segmentCount,"host":info.url.host ?? ""])
      } catch { emit(["route":name,"stage":"hls","provider":id,"elapsed":Date().timeIntervalSince(hlsStart),"errorCode":(error as NSError).code,"error":error.localizedDescription]) }
     }
    } catch { emit(["route":name,"stage":"detail","provider":id,"elapsed":Date().timeIntervalSince(begin),"errorCode":(error as NSError).code,"error":error.localizedDescription]) }
   }
  }
 }
}
