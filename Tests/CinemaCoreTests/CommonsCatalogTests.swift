import Foundation
import Testing
@testable import CinemaCore
struct CommonsCatalogTests {
 let p = SourceProvider(id:"wikimedia-commons", name:"Wikimedia Commons", endpoint:URL(string:"https://commons.wikimedia.org")!)
 let fixture = Data(#"{"query":{"searchinfo":{"totalhits":1},"pages":[{"pageid":120253709,"title":"File:Builder in Oblast.mpg","index":1,"videoinfo":[{"url":"https://upload.wikimedia.org/wikipedia/commons/3/3d/Builder_in_Oblast.mpg","descriptionurl":"https://commons.wikimedia.org/wiki/File:Builder_in_Oblast.mpg","mime":"video/mpeg","extmetadata":{"LicenseShortName":{"value":"CC BY-SA 4.0"},"Artist":{"value":"Author"},"LicenseUrl":{"value":"https://creativecommons.org/licenses/by-sa/4.0"},"Restrictions":{"value":""}}}]}]}}"#.utf8)
 @Test func queryIsBoundedAndEscapesText() throws {
  let url=try CommonsCatalog.searchURL(query:"builder\" AND foo",page:2)
  let q=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
  #expect(q.first(where:{$0.name=="gsroffset"})?.value == "30")
  #expect(q.first(where:{$0.name=="gsrsearch"})?.value == "filemime:video/mpeg \"builder\\\" AND foo\"")
  #expect(throws:(any Error).self) { try CommonsCatalog.searchURL(query:"a",page:0) }
 }
 @Test func showsLicensedMpegAndAttribution() throws {
  let page=try CommonsCatalog.parsePage(fixture,provider:p,page:1)
  #expect(page.titles.count==1)
  #expect(page.titles[0].id=="120253709")
  #expect(page.titles[0].summary.contains("CC BY-SA 4.0"))
  #expect(page.titles[0].summary.contains("Author"))
  let detail=try CommonsCatalog.parseDetail(fixture,title:page.titles[0])
  #expect(detail.lines[0].episodes[0].url.host=="upload.wikimedia.org")
 }
 @Test func doesNotTrustUnlicensedExternalOrUnsupportedMedia() throws {
  for replacement in ["https://evil.test/file.mpg","https://upload.wikimedia.org.evil.test/file.mpg"] {
   let bad=String(decoding:fixture,as:UTF8.self).replacingOccurrences(of:"https://upload.wikimedia.org/wikipedia/commons/3/3d/Builder_in_Oblast.mpg",with:replacement)
   #expect(try CommonsCatalog.parsePage(Data(bad.utf8),provider:p,page:1).titles.isEmpty)
  }
  let badMime=String(decoding:fixture,as:UTF8.self).replacingOccurrences(of:"video/mpeg",with:"video/webm")
  #expect(try CommonsCatalog.parsePage(Data(badMime.utf8),provider:p,page:1).titles.isEmpty)
  let badLicense=String(decoding:fixture,as:UTF8.self).replacingOccurrences(of:"CC BY-SA 4.0",with:"Unknown")
  #expect(try CommonsCatalog.parsePage(Data(badLicense.utf8),provider:p,page:1).titles.isEmpty)
 }
 @Test func emptyResultsAndContinuationAreHonest() throws {
  let empty=try CommonsCatalog.parsePage(Data(#"{"batchcomplete":true}"#.utf8),provider:p,page:1)
  #expect(empty.titles.isEmpty && !empty.hasMore)
  let json=String(decoding:fixture,as:UTF8.self).replacingOccurrences(of:"{\"query\"",with:"{\"continue\":{\"gsroffset\":30,\"continue\":\"gsroffset||\"},\"query\"")
  let page=try CommonsCatalog.parsePage(Data(json.utf8),provider:p,page:1)
  #expect(page.hasMore)
  #expect(throws:(any Error).self) { try CommonsCatalog.parsePage(Data(#"{"error":{"code":"ratelimited"}}"#.utf8),provider:p,page:1) }
 }
}

struct CommonsGroupingTests {
 @Test func aShortVideoCannotMergeWithAFullFilmOfSameName() {
  let short = MediaTitle(id:"23",title:"Moon",year:"",posterURL:nil,summary:"",providerID:"wikimedia-commons",providerName:"Wikimedia Commons",category:"开放短视频")
  let full = MediaTitle(id:"movie",title:"Moon",year:"2009",posterURL:nil,summary:"",providerID:"film",providerName:"Film",category:"电影")
  #expect(CatalogGrouping.groups([short,full]).count == 2)
 }
}

struct CommonsYearGroupingTests {
 @Test func commonsYearCannotSplitTheMatchingFilmSources() {
  let unknown = MediaTitle(id:"1",title:"Moon",year:"",posterURL:nil,summary:"",providerID:"film-a",providerName:"A")
  let known = MediaTitle(id:"2",title:"Moon",year:"2009",posterURL:nil,summary:"",providerID:"film-b",providerName:"B")
  let clip = MediaTitle(id:"3",title:"Moon",year:"2025",posterURL:nil,summary:"",providerID:"wikimedia-commons",providerName:"Commons",category:"开放短视频")
  let groups = CatalogGrouping.groups([unknown, known, clip])
  #expect(groups.count == 2)
  #expect(groups.first(where:{$0.sources.contains(where:{$0.providerID == "film-a"})})?.sources.count == 2)
 }
}
