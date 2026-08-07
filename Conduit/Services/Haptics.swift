//
//  Haptics.swift
//  Conduit
//
//  Centralized haptic feedback with a user-toggleable preference.
//  Usage: Haptics.light() / Haptics.medium() / Haptics.success() / Haptics.selection()
//

import SwiftUI

enum Haptics {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "conduit.haptics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "conduit.haptics") }
    }

    static func light() {
        guard enabled else { return }
        lightGenerator.impactOccurred()
        lightGenerator.prepare()
    }

    static func medium() {
        guard enabled else { return }
        mediumGenerator.impactOccurred()
        mediumGenerator.prepare()
    }

    static func rigid() {
        guard enabled else { return }
        rigidGenerator.impactOccurred()
        rigidGenerator.prepare()
    }

    static func success() {
        guard enabled else { return }
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    static func error() {
        guard enabled else { return }
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }

    static func warning() {
        guard enabled else { return }
        notificationGenerator.notificationOccurred(.warning)
        notificationGenerator.prepare()
    }

    static func selection() {
        guard enabled else { return }
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func prepare() {
        lightGenerator.prepare()
        mediumGenerator.prepare()
        rigidGenerator.prepare()
        notificationGenerator.prepare()
        selectionGenerator.prepare()
    }
}
