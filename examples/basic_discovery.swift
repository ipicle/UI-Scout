#!/usr/bin/env swift

import Foundation

// Simple example showing how to find UI elements
print("=== UI Scout Element Discovery Example ===")

// This would typically import UIScout, but for demo purposes we'll simulate
struct MockElement {
    let role: String
    let title: String?
    let bounds: CGRect
}

// Simulate finding elements
let mockElements = [
    MockElement(role: "button", title: "Submit", bounds: CGRect(x: 100, y: 200, width: 80, height: 30)),
    MockElement(role: "textField", title: nil, bounds: CGRect(x: 50, y: 150, width: 200, height: 25)),
    MockElement(role: "menu", title: "File", bounds: CGRect(x: 10, y: 10, width: 40, height: 20))
]

print("Found \(mockElements.count) elements:")
for (index, element) in mockElements.enumerated() {
    print("  [\(index + 1)] \(element.role)")
    if let title = element.title {
        print("      Title: \(title)")
    }
    print("      Bounds: \(element.bounds)")
}

print("\n=== Confidence Scoring Example ===")
let query = "submit button"
print("Query: '\(query)'")

// Simulate confidence scoring
for (index, element) in mockElements.enumerated() {
    var confidence = 0.0
    
    // Simple confidence calculation
    if element.role == "button" && element.title?.lowercased().contains("submit") == true {
        confidence = 0.95
    } else if element.role == "button" {
        confidence = 0.3
    } else {
        confidence = 0.1
    }
    
    print("  Element [\(index + 1)]: confidence = \(String(format: "%.2f", confidence))")
}

print("\n=== Ready for Integration ===")
print("To use with real UI automation:")
print("1. Build the Swift library: swift build")
print("2. Start the HTTP service: ./cli-tool serve")
print("3. Use the MCP tool in Claude Desktop or other AI assistant")
