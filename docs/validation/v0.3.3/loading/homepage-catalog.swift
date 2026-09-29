import Foundation
import CinemaCore
@main struct DiagnoseDiscover {
 static func main() async {
  let service = SourceService()
  for term in ["星际穿越", "庆余年", "怪奇物语", "绝命毒师", "火线第"] {
   let start = Date()
   let pages = await service.searchPages(query:term)
   let object: [String:Any] = ["term":term,"elapsed":Date().timeIntervalSince(start),"count":pages.reduce(0) { $0 + ($1.page?.titles.count ?? 0) },"sources":pages.map { ["id":$0.providerID,"count":$0.page?.titles.count ?? 0,"error":$0.error ?? ""] as [String:Any] }]
   let data = try! JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]); FileHandle.standardOutput.write(data + Data("\n".utf8))
  }
 }
}
