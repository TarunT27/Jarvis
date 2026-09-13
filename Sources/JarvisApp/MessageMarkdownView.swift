import SwiftUI
import JarvisCore

struct MessageMarkdownView:View {
    let content:String
    private func inline(_ text:String) -> AttributedString {
        (try? AttributedString(markdown:text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            ForEach(Array(MessageMarkdown.blocks(content).enumerated()),id:\.offset) { _,block in
                switch block {
                case .text(let text):
                    Text(inline(text)).textSelection(.enabled).lineSpacing(5)
                case .heading(let level,let text):
                    Text(inline(text)).font(level<=2 ? .title3:.headline).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                case .code(let language,let code):
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Text(language.isEmpty ? "Code":language).font(.caption).foregroundStyle(JarvisTheme.secondary)
                            Spacer()
                            Button("Copy code",systemImage:"doc.on.doc") {
                                NSPasteboard.general.clearContents();NSPasteboard.general.setString(code,forType:.string)
                            }.buttonStyle(.borderless).font(.caption)
                        }
                        ScrollView(.horizontal) { Text(code).font(.system(.callout,design:.monospaced)).textSelection(.enabled) }
                    }.padding(14).background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:12))
                }
            }
        }
    }
}
