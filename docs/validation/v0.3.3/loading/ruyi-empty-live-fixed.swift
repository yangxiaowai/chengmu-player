import Foundation
import CinemaCore
@main struct Probe {
 static func main() async throws {
  let provider = SourceProvider.defaults.first { $0.id == "ruyi" }!
  let result = await SourceService().searchPages(query:"火线第",providers:[provider])
  let entry = result[0]
  let object: [String:Any] = ["provider":entry.providerID,"query":"火线第","titleCount":entry.page?.titles.count ?? -1,"hasMore":entry.page?.hasMore ?? true,"error":entry.error ?? "","passed":entry.page?.titles.isEmpty == true && entry.error == nil]
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]));FileHandle.standardOutput.write(Data("\n".utf8))
 }
}
