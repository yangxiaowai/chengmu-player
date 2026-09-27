import Foundation
@main struct Check { static func main() async throws {
let service = SourceService()
let providers = SourceProvider.defaults.filter { ["ruyi","mdzy","wujin"].contains($0.id) }
var records: [[String:Any]] = []
for provider in providers {
 do {
  let catalog = try await service.browse(provider: provider)
  let category = catalog.categories.first { ["国产剧","大陆剧","内地剧"].contains($0.name) }
  let page = try await service.browse(provider:provider, categoryID:category?.id,page:2)
  records.append(["provider":provider.id,"categories":catalog.categories.count,"catalogTitles":catalog.titles.count,"page2":page.page,"page2Titles":page.titles.count,"category":category?.name ?? "missing"])
 } catch { records.append(["provider":provider.id,"error":error.localizedDescription]) }
}
let results = await service.searchPages(query:"爱情",providers:providers,pages:["ruyi":2,"mdzy":2,"wujin":2])
for result in results { records.append(["provider":result.providerID,"searchPage":result.page?.page ?? -1,"searchTitles":result.page?.titles.count ?? 0,"error":result.error ?? ""]) }
let bytes=try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys])
try bytes.write(to:URL(fileURLWithPath:"docs/validation/v0.2/catalog-service-integration.json"))
print(String(data:bytes,encoding:.utf8)!)
} }
