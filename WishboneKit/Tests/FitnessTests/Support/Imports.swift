/// The modules that Swift files import.
enum Imports {
  /// Each import in the file, in order. It reads attributes, access levels, and imports of one declaration.
  static func modules(in file: SourceFile) -> [(module: String, at: String.Index)] {
    let pattern =
      #"^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]+)*(?:(?:public|package|internal|fileprivate|private)[ \t]+)?"#
      + #"import[ \t]+(?:(?:struct|class|enum|protocol|typealias|func|let|var)[ \t]+)?(\w+)"#
    return file.matches(of: pattern).map { range in
      let statement = file.code[range]
      let afterImport = statement.split(whereSeparator: \.isWhitespace).last ?? ""
      return (String(afterImport.prefix { $0.isLetter || $0.isNumber || $0 == "_" }), range.lowerBound)
    }
  }

  /// Each import of a module that the test bans.
  static func findings(in files: [SourceFile], banned: (String) -> Bool) -> [Finding] {
    files.flatMap { file in
      modules(in: file).filter { banned($0.module) }.map { file.finding(at: $0.at, "import \($0.module)") }
    }
  }
}
