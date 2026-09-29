import Foundation
import CoreML
import QuartzCore

@main struct PlanProbe {
 static func main() async throws {
  guard CommandLine.arguments.count == 4 else { fatalError("Usage: plan MODEL.mlpackage OUTPUT.json all|gpu|ne") }
  let units=CommandLine.arguments[3]
  let config=MLModelConfiguration()
  switch units { case "all":config.computeUnits = .all; case "gpu":config.computeUnits = .cpuAndGPU; case "ne":config.computeUnits = .cpuAndNeuralEngine; default:fatalError("all|gpu|ne") }
  let start=CACurrentMediaTime()
  let url=try await MLModel.compileModel(at:URL(fileURLWithPath:CommandLine.arguments[1]))
  defer { try? FileManager.default.removeItem(at:url) }
  let plan=try await MLComputePlan.load(contentsOf:url,configuration:config)
  var operations:[[String:Any]]=[]
  func visit(_ block:MLModelStructure.Program.Block) {
   for op in block.operations {
    var row:[String:Any]=["operator":op.operatorName,"outputs":op.outputs.map(\.name)]
    if let usage=plan.deviceUsage(for:op) { row["supported"]=usage.supported.map(\.description);row["preferred"]=usage.preferred.description }
    if let cost=plan.estimatedCost(of:op) { row["estimated_cost_weight"]=cost.weight }
    operations.append(row)
    op.blocks.forEach(visit)
   }
  }
  switch plan.modelStructure { case .program(let program): for (_,function) in program.functions.sorted(by:{$0.key<$1.key}) {visit(function.block)};default:fatalError("Expected MLProgram") }
  let report:[String:Any]=["model":CommandLine.arguments[1],"units":units,"compile_and_plan_ms":(CACurrentMediaTime()-start)*1000,"available_devices":MLComputeDevice.allComputeDevices.map(\.description),"scope":"Core ML predicted placement and relative operation cost; not runtime utilization counters or milliseconds.","operations":operations]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
  print("\(units) plan: \(operations.count) operations; wrote \(CommandLine.arguments[2])")
 }
}
