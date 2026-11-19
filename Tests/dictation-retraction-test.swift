import Foundation

@main
struct DictationRetractionTest {
    static func main() {
        var failures = 0
        func expect(_ spoken: String, _ expected: String) {
            let actual = DictationRetraction.applying(spoken)
            guard actual != expected else { return }
            print("FAIL: \(spoken)\n  expected: \(expected)\n  actual:   \(actual)")
            failures += 1
        }

        expect(
            "You are a top 0.0.01 designer. No, scrap that. You are a top 0.001% product designer.",
            "You are a top 0.001% product designer.")
        expect("Send it Friday. Scratch that, send it Monday.", "Send it Monday.")
        expect("Call Ana, no, scratch that, call Ben.", "Call Ben.")
        expect("Meet at noon. Never mind. Meet at one.", "Meet at one.")
        expect("It costs ten dollars. I take that back. It costs twelve.", "It costs twelve.")
        expect("The plan is simple. Let me rephrase. The plan is short.", "The plan is short.")
        expect("Book the room. Strike that.", "Book the room. Strike that.")
        expect("Draft the email. Ignore the last statement. Draft the memo.", "Draft the memo.")
        expect("Book the room. Forget what I just said.", "")
        expect("Use red. Oh wait, forget that. Use blue.", "Use blue.")
        expect("Ship the first draft.\nShip it Friday. Strike that, ship it Monday.", "Ship the first draft.\nShip it Monday.")
        expect("Call Ana, no, forget that, call Ben.", "Call Ben.")

        expect("You can ignore that warning.", "You can ignore that warning.")
        expect("Don't forget that.", "Don't forget that.")
        expect("Please delete that file.", "Please delete that file.")
        expect("We need to start over.", "We need to start over.")
        expect("Version 1.2.3 ships today.", "Version 1.2.3 ships today.")
        expect("Hello.  Two spaces stay.", "Hello.  Two spaces stay.")

        expect("Thanks for the help. Never mind, I found it.", "Thanks for the help. Never mind, I found it.")
        expect("If the build fails, start over.", "If the build fails, start over.")
        expect("There's a typo on line three. Ignore that.", "There's a typo on line three. Ignore that.")
        expect("Book the room. Never mind.", "Book the room. Never mind.")
        expect("I said I'd come. I take that back, I'm busy.", "I said I'd come. I take that back, I'm busy.")
        expect("The old logo is attached. Forget that, the new one is better.",
               "The old logo is attached. Forget that, the new one is better.")
        expect("Let me rephrase. I need help.", "Let me rephrase. I need help.")
        expect("The vendor quote is too high. Scrap that.", "The vendor quote is too high. Scrap that.")
        expect("Your draft has a typo. Scratch that, we can fix it later.",
               "Your draft has a typo. Scratch that, we can fix it later.")

        let conditional = "If the build fails, start over. The build needs a clean cache."
        let invoice = "Save the receipt, email Ana the invoice, no, scratch that, email Ben the invoice."
        let correctedInvoice = "Save the receipt, email Ben the invoice."
        let chain = "Call Ana, scratch that, call Ben, scratch that, call Sam."
        let amount = "Keep $50 for supplies. Charge $10. Scratch that. Charge $12."
        expect(conditional, conditional)
        expect(invoice, correctedInvoice)
        expect("Save the receipt and email Ana the invoice, scratch that, email Ben the invoice.",
               "Save the receipt and email Ben the invoice.")
        expect(chain, "Call Sam.")
        expect(amount, "Keep $50 for supplies. Charge $12.")
        let unpunctuated = "Save the receipt and call Ana no scratch that call Ben"
        let conditionalCorrection = "Call me if it rains. Scratch that. Call me if it snows."
        expect(unpunctuated, "Save the receipt and call Ben")
        expect("Call Ana no scratch that call Ben no scratch that call Sam", "Call Sam")
        expect(conditionalCorrection, "Call me if it snows.")
        let literal = "Wait, scratch that itch before we leave."
        expect(literal, literal)
        expect("Call me to scratch that itch. Scratch that. Call me to book a room.", "Call me to book a room.")
        expect("Call Ana scratch that call Ben", "Call Ben")

        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); failures += 1 }
        }
        check(!DictationRetraction.containsCue(literal), "A literal phrase should use ordinary Smart cleanup")
        let checks = [
            (conditional, conditional, true),
            (conditional, "The build needs a clean cache.", false),
            (invoice, correctedInvoice, true),
            (invoice, "Email Ben the invoice.", false),
            (invoice, "Save the receipt, email Ana the invoice.", false),
            (chain, "Call Sam.", true),
            (chain, "Call Ben.", false),
            (unpunctuated, "Save the receipt and call Ben.", true),
            (unpunctuated, "Call Ben.", false),
            (conditionalCorrection, "Call me if it snows.", true),
            ("Use red. Scratch that. Make it blue.", "Make it blue.", true),
            ("Use red. Scratch that. Make it blue.", "Make it green.", false),
            ("Book the room. Forget what I just said.", "", true),
            ("Book the room. Forget what I just said.", "Book the room.", false),
            (amount, "Keep $50 for supplies. Charge $12.", true),
            (amount, "Keep $50 for supplies. Charge $10.", false),
            (amount, "Keep $5 for supplies. Charge $12.", false),
            ("Charge $10. Scratch that. Charge $.50.", "Charge $50.", false),
        ]
        for (raw, output, expected) in checks {
            check(DictationRetraction(raw).accepts(output) == expected, "Smart edit of \(raw): \(output)")
        }

        let plan = DictationRetraction(amount)
        let cut = amount.range(of: " Scratch")!.lowerBound
        let beforeCharge = amount.range(of: "Charge $10")!.lowerBound
        check(plan.crossesBoundary(cut), "The prepared section ends before its take-back")
        check(!plan.crossesBoundary(beforeCharge), "An earlier section can still be reused")
        let sections = plan.keepingContext(in: [amount.startIndex..<cut, cut..<amount.endIndex])
        check(sections.map { String(amount[$0]) } == ["Keep $50 for supplies. ", "Charge $10. Scratch that. Charge $12."],
              "A split correction should reach the model in one section")

        if failures > 0 {
            print("\(failures) retraction case(s) failed")
            exit(1)
        }
        print("dictation-retraction-test: all cases passed")
    }
}
