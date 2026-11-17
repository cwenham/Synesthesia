import Foundation
import LanguageClient
import Testing
@testable import SynesthesiaUI

struct NewModuleTests {
    private func verb(_ json: String) throws -> VerbEntry {
        try JSONDecoder().decode(VerbEntry.self, from: Data(json.utf8))
    }

    @Test func aNewModulesLineHasItsValuesQuotedWhereTheyAreText() throws {
        let fetch = try verb("""
            {"verb": "Fetch", "inflection": "HTTP", "role": "step", "kind": "inflection", "takes": [], "emits": [],
             "parameters": [
               {"name": "url", "type": "text", "positional": true, "required": true, "perMessage": true},
               {"name": "timeout", "type": "duration", "positional": false, "required": false, "perMessage": false, "default": "1m40s"}]}
            """)
        #expect(NewModule.line(for: fetch, values: ["url": "https://example.com", "timeout": "5s"], name: "Check")
            == #"Fetch.HTTP "https://example.com" timeout=5s as Check"#)
        // Already quoted, or left out, it's written as given.
        #expect(NewModule.line(for: fetch, values: ["url": #""{msg.Url}""#], name: nil) == #"Fetch.HTTP "{msg.Url}""#)
        let interval = try verb("""
            {"verb": "Interval", "inflection": "Interval", "role": "source", "kind": "source", "takes": [], "emits": [],
             "parameters": [{"name": "period", "type": "duration", "positional": true, "required": true, "perMessage": false}]}
            """)
        #expect(NewModule.line(for: interval, values: ["period": "1s"], name: "") == "Interval 1s")
    }

    @Test func editsAreSaidInWords() {
        #expect(EditWords.describe(.insert("Where x", after: "m3")) == "insert Where x after m3")
        #expect(EditWords.describe(.setModifier("+0", "buffer", to: "10")) == "set @buffer=10 on the module edit 1 adds")
        #expect(EditWords.describe(.removeBranch("m4")) == "remove m4 and everything under it")
    }
}
