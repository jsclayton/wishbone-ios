import Foundation

/// The parts of `project.pbxproj` that the fitness tests read.
struct XcodeProject {
  private let objects: [String: [String: Any]]

  init(at url: URL) throws {
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
    guard let root = plist as? [String: Any], let objects = root["objects"] as? [String: [String: Any]] else {
      throw Unreadable(what: "project.pbxproj has no objects")
    }
    self.objects = objects
  }

  /// The names of the project's targets, in order.
  var targets: [String] {
    objects.values.filter { $0["isa"] as? String == "PBXNativeTarget" }.compactMap { $0["name"] as? String }.sorted()
  }

  /// The package products in the target's "Link Binary With Libraries" phase, in order. This is what the target links.
  func linkedPackageProducts(of target: String) throws -> [String] {
    let phases = try references(from: object(ofTarget: target), "buildPhases")
    let frameworks = phases.filter { $0["isa"] as? String == "PBXFrameworksBuildPhase" }
    return try frameworks.flatMap { try references(from: $0, "files") }.map { file in
      guard let id = file["productRef"] as? String, let name = objects[id]?["productName"] as? String else {
        throw Unreadable(what: "\(target) links something that is not a package product")
      }
      return name
    }.sorted()
  }

  /// The package products that the target says it depends on, in order.
  func packageProductDependencies(of target: String) throws -> [String] {
    try references(from: object(ofTarget: target), "packageProductDependencies").map { product in
      guard let name = product["productName"] as? String else {
        throw Unreadable(what: "\(target) has a package product with no name")
      }
      return name
    }.sorted()
  }

  /// The value of a build setting in each of the target's configurations, by configuration name. A configuration
  /// that doesn't set it is left out.
  func buildSetting(_ key: String, of target: String) throws -> [String: String] {
    guard let id = try object(ofTarget: target)["buildConfigurationList"] as? String, let list = objects[id] else {
      throw Unreadable(what: "\(target) has no build configurations")
    }
    var values: [String: String] = [:]
    for configuration in try references(from: list, "buildConfigurations") {
      guard let name = configuration["name"] as? String else {
        throw Unreadable(what: "\(target) has a build configuration with no name")
      }
      if let value = (configuration["buildSettings"] as? [String: Any])?[key] as? String {
        values[name] = value
      }
    }
    return values
  }

  private func object(ofTarget name: String) throws -> [String: Any] {
    let found = objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == name }
    guard let found else { throw Unreadable(what: "no target named \(name)") }
    return found
  }

  private func references(from object: [String: Any], _ key: String) throws -> [[String: Any]] {
    try (object[key] as? [String] ?? []).map { id in
      guard let referenced = objects[id] else { throw Unreadable(what: "no object \(id)") }
      return referenced
    }
  }

  struct Unreadable: Error {
    let what: String
  }
}
