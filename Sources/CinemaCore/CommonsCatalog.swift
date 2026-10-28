import Foundation

/// Commons video metadata and licenses are supplied by contributors; they are not independent rights certification.
enum CommonsCatalog {
 static let id = "wikimedia-commons"
 static let endpoint = URL(string:"https://commons.wikimedia.org")!
 static let pageSize = 30
 static func recognizes(_ provider:SourceProvider)->Bool { provider.id == id && provider.endpoint == endpoint }
 static func searchURL(query:String,page:Int)throws->URL {
  guard (1...1000).contains(page) else { throw SourceError.invalidPage }
  let input=String(query.trimmingCharacters(in:.whitespacesAndNewlines).prefix(200)).replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
  let search="filemime:video/mpeg" + (input.isEmpty ? "" : " \"\(input)\"")
  return try api([URLQueryItem(name:"generator",value:"search"), URLQueryItem(name:"gsrsearch",value:search), URLQueryItem(name:"gsrnamespace",value:"6"), URLQueryItem(name:"gsrlimit",value:String(pageSize)), URLQueryItem(name:"gsrinfo",value:"totalhits"), URLQueryItem(name:"gsroffset",value:String((page-1)*pageSize))])
 }
 static func detailURL(id:String)throws->URL {
  guard let number=Int64(id),number>0,id==String(number) else { throw SourceError.invalidURL }
  return try api([URLQueryItem(name:"pageids",value:id)])
 }
 private static func api(_ specific:[URLQueryItem])throws->URL {
  var c=URLComponents(string:"https://commons.wikimedia.org/w/api.php")!
  c.queryItems=[URLQueryItem(name:"action",value:"query"), URLQueryItem(name:"format",value:"json"),URLQueryItem(name:"formatversion",value:"2"),URLQueryItem(name:"prop",value:"videoinfo"),URLQueryItem(name:"viprop",value:"url|mime|size|extmetadata")]+specific
  guard let url=c.url else { throw SourceError.invalidURL };return url
 }
 static func parsePage(_ data:Data,provider:SourceProvider,page:Int)throws->CatalogPage {
  guard (1...1000).contains(page), let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],root["error"] == nil else { throw SourceError.invalidResponse }
  let raw: [[String:Any]]
  if let query=root["query"] as? [String:Any],let pages=query["pages"] as? [[String:Any]] { raw=pages }
  else if root["batchcomplete"] != nil { raw=[] }
  else { throw SourceError.invalidResponse }
  guard raw.count <= pageSize else { throw SourceError.invalidResponse }
  let ordered=raw.sorted { (integer($0["index"]) ?? Int.max) < (integer($1["index"]) ?? Int.max) }
  var seen=Set<String>()
  let titles=ordered.compactMap { row -> MediaTitle? in
   guard let value=entry(row,provider:provider),seen.insert(value.title.id).inserted else { return nil };return value.title
  }
  let hasNext=(root["continue"] as? [String:Any]).flatMap{integer($0["gsroffset"])} == page*pageSize
  let total=(root["query"] as? [String:Any]).flatMap { ($0["searchinfo"] as? [String:Any]).flatMap { integer($0["totalhits"]) } } ?? (raw.isEmpty ? 0 : -1)
  guard total >= 0 else {throw SourceError.invalidResponse}
  return CatalogPage(providerID:provider.id,titles:titles,categories:[],page:page,pageCount:page+(hasNext ? 1 : 0),total:total)
 }
 static func parseDetail(_ data:Data,title:MediaTitle)throws->MediaDetail {
  guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any], root["error"] == nil,
        let query=root["query"] as? [String:Any],let rows=query["pages"] as? [[String:Any]],rows.count==1 else {throw SourceError.emptyDetail}
  let provider=SourceProvider(id:title.providerID,name:title.providerName,endpoint:endpoint)
  guard let parsed=entry(rows[0],provider:provider),parsed.title.id==title.id else {throw SourceError.emptyDetail}
  let id="commons:\(title.id):original"
  return MediaDetail(title:parsed.title,lines:[PlaybackLine(id:id,name:"原始视频",episodes:[Episode(id:id,name:"正片",url:parsed.url,number:nil)])])
 }
 private static func integer(_ value:Any?)->Int? { (value as? Int) ?? (value as? String).flatMap(Int.init) }
 private static func entry(_ row:[String:Any],provider:SourceProvider)->(title:MediaTitle,url:URL)? {
  guard let id=integer(row["pageid"]),id>0,let name=row["title"] as? String,name.hasPrefix("File:"),
        let entries=row["videoinfo"] as? [[String:Any]],entries.count==1,let info=entries.first,info["mime"] as? String == "video/mpeg",
        let raw=info["url"] as? String,let url=URL(string:raw),url.scheme?.lowercased()=="https",url.host?.lowercased()=="upload.wikimedia.org",url.user==nil,url.password==nil,url.port==nil,
        url.path.hasPrefix("/wikipedia/commons/"),["mpg","mpeg"].contains(url.pathExtension.lowercased()),
        let rawDescription=info["descriptionurl"] as? String,let source=URL(string:rawDescription),source.scheme?.lowercased()=="https",source.host?.lowercased()=="commons.wikimedia.org",source.user==nil,source.password==nil,source.port==nil,
        let metadata=info["extmetadata"] as? [String:Any] else {return nil}
  func value(_ key:String)->String { ((metadata[key] as? [String:Any])?["value"] as? String ?? "").replacingOccurrences(of:"<[^>]+>",with:" ",options:.regularExpression).replacingOccurrences(of:"\\s+",with:" ",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines) }
  let license=value("LicenseShortName"), author=value("Artist"), restrictions=value("Restrictions")
  guard restrictions.isEmpty,!license.isEmpty,(license.hasPrefix("CC ") || license.hasPrefix("CC0") || license == "Public domain") else {return nil}
  if license != "Public domain" {
   guard let declared=URL(string:value("LicenseUrl")),["http","https"].contains(declared.scheme?.lowercased() ?? ""),
         ["creativecommons.org","www.creativecommons.org"].contains(declared.host?.lowercased() ?? ""),
         declared.user==nil,declared.password==nil,declared.port==nil,
         declared.path.hasPrefix("/licenses/") || declared.path.hasPrefix("/publicdomain/") else {return nil}
  }
  let summary="开放短视频 · 许可：\(license) · 作者：\(author.isEmpty ? "未提供" : author) · 作品详情：\(source.absoluteString) · 版权、格式兼容性与地区可用性需核实。"
  let filename=String(name.dropFirst(5)).replacingOccurrences(of:"_",with:" ")
  let display=(filename as NSString).deletingPathExtension
  return (MediaTitle(id:String(id),title:display,year:"",posterURL:nil,summary:summary,providerID:provider.id,providerName:provider.name,category:"开放短视频"),url)
 }
}
