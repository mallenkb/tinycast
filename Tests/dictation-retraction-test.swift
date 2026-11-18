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

        if failures > 0 {
            print("\(failures) retraction case(s) failed")
            exit(1)
        }
        print("dictation-retraction-test: all cases passed")
    }
}
