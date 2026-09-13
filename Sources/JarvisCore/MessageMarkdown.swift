import Foundation

/// A bounded, data-only Markdown subset. No HTML, scripts, remote images or code execution.
public enum MessageMarkdown {
    public enum Block:Equatable,Sendable {
        case text(String)
        case code(language:String,content:String)
        case heading(level:Int,content:String)
    }
    public static func blocks(_ source:String) -> [Block] {
        var result:[Block]=[],text:[String]=[],code:[String]=[]
        var fence:String?,language=""
        func flush() { if !text.isEmpty { result.append(.text(text.joined(separator:"\n")));text=[] } }
        for line in source.components(separatedBy:"\n") {
            let trimmed=line.trimmingCharacters(in:.whitespaces)
            if let current=fence {
                if trimmed.count>=current.count && trimmed.allSatisfy({$0==current.first!}) {
                    result.append(.code(language:language,content:code.joined(separator:"\n")));code=[];fence=nil
                } else { code.append(line) }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush();let character=trimmed.first!
                let count=trimmed.prefix(while:{$0==character}).count
                fence=String(repeating:String(character),count:count)
                language=String(trimmed.dropFirst(count).prefix(40))
            } else {
                let level=line.prefix(while:{$0=="#"}).count
                if (1...6).contains(level),line.dropFirst(level).first==" " {
                    flush();result.append(.heading(level:level,content:String(line.dropFirst(level+1))))
                } else { text.append(line) }
            }
        }
        if fence != nil { result.append(.code(language:language,content:code.joined(separator:"\n"))) }
        flush();return result
    }
}
