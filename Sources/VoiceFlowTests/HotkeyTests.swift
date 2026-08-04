import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

func runHotkeyTests(_ s: TestSuite) {
    let optionMask = HotkeyMatcher.carbonOption
    let spaceKey: UInt32 = 0x31   // kVK_Space, the default push-to-talk key

    s.test("decode maps Carbon masks to ModifierSet") { s in
        s.expectEqual(HotkeyMatcher.decode(carbonMask: HotkeyMatcher.carbonOption), [.option])
        s.expectEqual(HotkeyMatcher.decode(carbonMask: HotkeyMatcher.carbonCommand | HotkeyMatcher.carbonShift),
                      [.command, .shift])
        s.expectEqual(HotkeyMatcher.decode(carbonMask: 0), [])
    }

    s.test("matches requires all configured modifiers present") { s in
        s.expect(HotkeyMatcher.matches(required: [.option], present: [.option]))
        s.expectFalse(HotkeyMatcher.matches(required: [.option], present: []))
        s.expectFalse(HotkeyMatcher.matches(required: [.command, .option], present: [.option]))
    }

    s.test("extra held modifiers do not break the match") { s in
        s.expect(HotkeyMatcher.matches(required: [.option], present: [.option, .shift]))
    }

    s.test("default ⌥Space triggers only with Option held on the Space key") { s in
        s.expect(HotkeyMatcher.triggers(configuredKeyCode: spaceKey, configuredCarbonMask: optionMask,
                                        eventKeyCode: spaceKey, present: [.option]))
        s.expectFalse(HotkeyMatcher.triggers(configuredKeyCode: spaceKey, configuredCarbonMask: optionMask,
                                             eventKeyCode: spaceKey, present: []),
                      "no Option ⇒ no trigger")
        s.expectFalse(HotkeyMatcher.triggers(configuredKeyCode: spaceKey, configuredCarbonMask: optionMask,
                                             eventKeyCode: 0x00, present: [.option]),
                      "wrong key ⇒ no trigger")
    }

    s.test("nil configured keyCode matches any key with the modifiers") { s in
        s.expect(HotkeyMatcher.triggers(configuredKeyCode: nil, configuredCarbonMask: optionMask,
                                        eventKeyCode: 0x2A, present: [.option]))
        s.expectFalse(HotkeyMatcher.triggers(configuredKeyCode: nil, configuredCarbonMask: optionMask,
                                             eventKeyCode: 0x2A, present: [.command]))
    }

    s.test("default hotkey configuration decodes to Option") { s in
        let config = HotkeyConfiguration.defaultPushToTalk
        s.expectEqual(HotkeyMatcher.decode(carbonMask: config.modifierFlags), [.option])
        s.expectEqual(config.keyCode, spaceKey)
    }
}
