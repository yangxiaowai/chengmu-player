import Foundation
import CinemaCore
@main struct EmptyCatalogRegression {
 static func main() throws {
  let provider = SourceProvider(id:"fixture",name:"Fixture",endpoint:URL(string:"https://catalog.example/api")!)
  let valid = [#"{"code":1,"page":1,"pagecount":0,"limit":20,"total":0,"list":null}"#,#"{"code":"200","page":"1","pagecount":"0","total":"0","list":null}"#]
  let invalid = [#"{"code":0,"pagecount":0,"total":0,"list":null}"#,#"{"code":1,"pagecount":1,"total":1,"list":null}"#,#"{"code":1,"pagecount":0,"list":null}"#,#"{"code":1,"total":0,"list":null}"#,#"{"pagecount":0,"total":0,"list":null}"#,#"{"code":1,"pagecount":0,"total":0}"#]
  var good=0,bad=0
  for json in valid { do { let page=try SourceService.parsePage(data:Data(json.utf8),provider:provider); if page.titles.isEmpty && page.total==0 && page.pageCount==1 && !page.hasMore { good += 1 } } catch {} }
  for json in invalid { do { _=try SourceService.parsePage(data:Data(json.utf8),provider:provider) } catch { bad += 1 } }
  let passed=good==valid.count && bad==invalid.count
  let result:[String:Any] = ["passed":passed,"validEmptyAccepted":good,"validEmptyExpected":valid.count,"malformedRejected":bad,"malformedExpected":invalid.count]
  let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);FileHandle.standardOutput.write(data+Data("\n".utf8));exit(passed ? 0:1)
 }
}
