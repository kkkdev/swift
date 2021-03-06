//===--- ArrayBridge.swift - Tests of Array casting and bridging ----------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// RUN: rm -rf %t
// RUN: mkdir -p %t
//
// RUN: %target-clang %S/Inputs/ArrayBridge/ArrayBridge.m -c -o %t/ArrayBridgeObjC.o -g
// RUN: %target-build-swift %s -I %S/Inputs/ArrayBridge/ -Xlinker %t/ArrayBridgeObjC.o -o %t/ArrayBridge

// RUN: %target-run %t/ArrayBridge
// REQUIRES: executable_test
// REQUIRES: objc_interop

import Foundation
import ArrayBridgeObjC
import StdlibUnittest
let tests = TestSuite("ArrayBridge")

var trackedCount = 0
var nextBaseSerialNumber = 0

@objc protocol Fooable {
  func foo()
}

@objc protocol Barable {
  func bar()
}

@objc protocol Bazable {
  func baz()
}

/// A type that will be bridged verbatim to Objective-C
class Base : NSObject, Fooable {
  func foo() { }

  required init(_ value: Int) {
    trackedCount += 1
    nextBaseSerialNumber += 1
    serialNumber = nextBaseSerialNumber
    self.value = value
  }
  
  deinit {
    assert(serialNumber > 0, "double destruction!")
    trackedCount -= 1
    serialNumber = -serialNumber
  }

  override func isEqual(_ other: AnyObject?) -> Bool {
    return (other as? Base)?.value == self.value
  }
  
  var value: Int
  var serialNumber: Int
}

class Subclass : Base, Barable {
  func bar() { }
}

var bridgeFromOperationCount = 0
var bridgeToOperationCount = 0

/// A value type that's bridged using _ObjectiveCBridgeable
struct BridgeableValue : _ObjectiveCBridgeable, Equatable {
  func _bridgeToObjectiveC() -> Subclass {
    bridgeToOperationCount += 1
    return Subclass(trak.value)
  }

  static func _isBridgedToObjectiveC() -> Bool {
    return true
  }

  static func _forceBridgeFromObjectiveC(
    _ x: Subclass,
    result: inout BridgeableValue?
  ) {
    assert(x.value >= 0, "not bridged")
    bridgeFromOperationCount += 1
    result = BridgeableValue(x.value)
  }

  static func _conditionallyBridgeFromObjectiveC(
    _ x: Subclass,
    result: inout BridgeableValue?
  ) -> Bool {
    if x.value >= 0 {
      result = BridgeableValue(x.value)
      return true
    }

    result = nil
    return false
  }

  static func _unconditionallyBridgeFromObjectiveC(_ source: Subclass?)
      -> BridgeableValue {
    var result: BridgeableValue? = nil
    _forceBridgeFromObjectiveC(source!, result: &result)
    return result!
  }

  init(_ value: Int) {
    self.trak = Base(value)
  }
  
  static func resetStats() {
    bridgeFromOperationCount = 0
    bridgeToOperationCount = 0
  }
  
  var trak: Base
}

func == (lhs: BridgeableValue, rhs: BridgeableValue) -> Bool {
  return lhs.trak.value == rhs.trak.value 
}

// A class used to test various Objective-C thunks.
class Thunks : NSObject {
  func createSubclass(_ value: Int) -> AnyObject {
    return Subclass(value)
  }
  
  @objc func acceptSubclassArray(
    _ x: [Subclass],
    expecting expected: NSArray
  )  {
    expectEqualSequence(
      expected.lazy.map { ObjectIdentifier($0) },
      x.lazy.map { ObjectIdentifier($0) }
    )
  }

  @objc func produceSubclassArray(
    _ expectations: NSMutableArray
  ) -> [Subclass] {
    var array: [Subclass] = []
    for i in 0..<5 {
      array.append(Subclass(i))
      expectations.add(array[i])
    }
    return array
  }

  @objc func checkProducedSubclassArray(
    _ produced: NSArray, expecting expected: NSArray
  ) {
    expectEqualSequence(
      expected.lazy.map { ObjectIdentifier($0) },
      produced.lazy.map { ObjectIdentifier($0) }
    )
  }
  
  @objc func acceptBridgeableValueArray(_ raw: NSArray) {
    let x = raw as! [BridgeableValue]
    expectEqualSequence(
      raw.lazy.map { $0 as! BridgeableValue },
      x
    )
  }

  @objc func produceBridgeableValueArray() -> NSArray {
    var array: [BridgeableValue] = []
    for i in 0..<5 {
      array.append(BridgeableValue(i))
    }
    return array as NSArray
  }
  
  @objc func checkProducedBridgeableValueArray(_ produced: NSArray) {
    expectEqualSequence(
      0..<5,
      produced.lazy.map { ($0 as! Subclass).value })
  }
}


//===--- Bridged Verbatim -------------------------------------------------===//
// Base is "bridged verbatim"
//===----------------------------------------------------------------------===//

tests.test("testBridgedVerbatim") {
  nextBaseSerialNumber = 0
  let bases: [Base] = [Base(100), Base(200), Base(300)]

  //===--- Implicit conversion to/from NSArray ------------------------------===//

  let basesConvertedToNSArray = bases as NSArray
  let firstBase = basesConvertedToNSArray.object(at: 0) as! Base
  expectEqual(100, firstBase.value)
  expectEqual(1, firstBase.serialNumber)

  // Create an ordinary NSArray, not a native one
  let nsArrayOfBase: NSArray = NSArray(object: Base(42))

  // NSArray can be unconditionally cast to [AnyObject]...
  let nsArrayOfBaseConvertedToAnyObjectArray = nsArrayOfBase as [AnyObject]

  // Capture the representation of the first element
  let base42: ObjectIdentifier
  do {
    let b = nsArrayOfBase.object(at: 0) as! Base
    expectEqual(42, b.value)
    base42 = ObjectIdentifier(b)
  }

  // ...with the same elements
  expectEqual(
    base42,
    ObjectIdentifier(nsArrayOfBaseConvertedToAnyObjectArray[0] as! Base))

  // Verify that NSArray class methods are inherited by a Swift bridging class.
  let className = String(reflecting: basesConvertedToNSArray.dynamicType)
  expectTrue(className.hasPrefix("Swift._ContiguousArrayStorage"))
  expectTrue(basesConvertedToNSArray.dynamicType.supportsSecureCoding)

  //===--- Up- and Down-casts -----------------------------------------------===//
  var subclass: [Subclass] = [Subclass(11), Subclass(22)]
  let subclass0 = subclass

  // upcast is implicit
  let subclassAsBases: [Base] = subclass
  expectEqual(subclass.count, subclassAsBases.count)
  for (x, y) in zip(subclass, subclassAsBases) {
    expectTrue(x === y)
  }

  // Arrays are logically distinct after upcast
  subclass[0] = Subclass(33)

  expectEqual([Subclass(33), Subclass(22)], subclass)
  expectEqual([Subclass(11), Subclass(22)], subclassAsBases)

  expectEqual(subclass0, subclassAsBases as! [Subclass])

  let subclassInBaseBuffer: [Base] = [Subclass(44), Subclass(55)]
  let subclass2 = subclassInBaseBuffer
  
  // Explicit downcast-ability is based on element type, not buffer type
  expectNotEmpty(subclassInBaseBuffer as? [Subclass])

  // We can up-cast to array of AnyObject
  let subclassAsAnyObjectArray: [AnyObject] = subclassInBaseBuffer
  expectEqual(subclass2, subclassAsAnyObjectArray.map { $0 as! Base })

  let downcastBackToBase = subclassAsAnyObjectArray as? [Base]
  expectNotEmpty(downcastBackToBase)

  if let downcastBackToSubclass = expectNotEmpty(subclassAsAnyObjectArray as? [Subclass]) {
    expectEqual(subclass2, downcastBackToSubclass)
  }

  if let downcastToProtocols = expectNotEmpty(subclassAsAnyObjectArray as? [Fooable]) {
    expectEqual(subclass2, downcastToProtocols.map { $0 as! Subclass })
  }

  if let downcastToProtocols = expectNotEmpty(subclassAsAnyObjectArray as? [Barable]) {
    expectEqual(subclass2, downcastToProtocols.map { $0 as! Subclass })
  }

  if let downcastToProtocols = expectNotEmpty(subclassAsAnyObjectArray as? [protocol<Barable, Fooable>]) {
    expectEqual(subclass2, downcastToProtocols.map { $0 as! Subclass })
  }

  expectEmpty(subclassAsAnyObjectArray as? [protocol<Barable, Bazable>])
}

tests.test("doTestSubclass") {
  testSubclass(Thunks())
}

//===--- Explicitly Bridged -----------------------------------------------===//
// BridgeableValue conforms to _ObjectiveCBridgeable
//===----------------------------------------------------------------------===//
tests.test("testExplicitlyBridged") {
  
  let bridgeableValues = [BridgeableValue(42), BridgeableValue(17)]
  
  let bridgeableValuesAsNSArray = bridgeableValues as NSArray
  expectEqual(2, bridgeableValuesAsNSArray.count)
  expectEqual(42, bridgeableValuesAsNSArray[0].value)
  expectEqual(17, bridgeableValuesAsNSArray[1].value)

  // Make sure we can bridge back.
  let roundTrippedValues = Swift._forceBridgeFromObjectiveC(
    bridgeableValuesAsNSArray, [BridgeableValue].self)

  // Expect equal values...
  expectEqualSequence(bridgeableValues, roundTrippedValues)
  // ...with the same identity for some reason? FIXME: understand why.
  expectFalse(
    zip(bridgeableValues, roundTrippedValues).contains { $0.trak !== $1.trak })

  // Make a real Cocoa NSArray of these...
  let cocoaBridgeableValues = NSArray(
    array: bridgeableValuesAsNSArray as [AnyObject])

  // ...and bridge *that* back
  let bridgedBackSwifts = Swift._forceBridgeFromObjectiveC(
    cocoaBridgeableValues, [BridgeableValue].self)
  
  // Expect equal, but distinctly created instances
  expectEqualSequence(bridgeableValues, bridgedBackSwifts)
  expectFalse(
    zip(bridgedBackSwifts, roundTrippedValues).contains { $0.trak === $1.trak })
  expectFalse(
    zip(bridgedBackSwifts, bridgeableValues).contains { $0.trak === $1.trak })

  let expectedSubclasses = [Subclass(42), Subclass(17)]
  let expectedBases = expectedSubclasses.lazy.map { $0 as Base }

  // Up-casts.
  let bridgeableValuesAsSubclasses: [Subclass] = bridgeableValues
  expectEqualSequence(expectedSubclasses, bridgeableValuesAsSubclasses)

  let bridgeableValuesAsBases: [Base] = bridgeableValues
  expectEqualSequence(expectedBases, bridgeableValuesAsBases)

  let bridgeableValuesAsAnyObjects: [AnyObject] = bridgeableValues
  expectEqualSequence(
    expectedBases,
    bridgeableValuesAsAnyObjects.lazy.map { $0 as! Base })

  // Downcasts of non-verbatim bridged value types to objects.
  do {
    let downcasted = bridgeableValues as [Subclass]
    expectEqualSequence(expectedSubclasses, downcasted)
  }

  do {
    let downcasted = bridgeableValues as [Base]
    expectEqualSequence(expectedBases, downcasted)
  }

  do {
    let downcasted = bridgeableValues as [AnyObject]
    expectEqualSequence(expectedBases, downcasted.map { $0 as! Base })
  }

  // Downcasts of up-casted arrays.
  if let downcasted = expectNotEmpty(
    bridgeableValuesAsAnyObjects as? [Subclass]
  ) {
    expectEqualSequence(expectedSubclasses, downcasted)
  }

  if let downcasted = bridgeableValuesAsAnyObjects as? [Base] {
    expectEqualSequence(expectedBases, downcasted)
  }

  // Downcast of Cocoa array to an array of classes.
  let wrappedCocoaBridgeableValues = cocoaBridgeableValues as [AnyObject]
  if let downcasted = wrappedCocoaBridgeableValues as? [Subclass] {
    expectEqualSequence(expectedSubclasses, downcasted)
  }

  // Downcast of Cocoa array to an array of values.
  if let downcasted = wrappedCocoaBridgeableValues as? [BridgeableValue] {
    expectEqualSequence(bridgeableValues, downcasted)
  }

  // Downcast of Cocoa array to an array of strings (which should fail)
  expectEmpty(wrappedCocoaBridgeableValues as? [String])

  // Downcast from an implicitly unwrapped optional array of AnyObjects.
  var wrappedCocoaBridgeableValuesIUO: [AnyObject]! = wrappedCocoaBridgeableValues
  if let downcasted = wrappedCocoaBridgeableValuesIUO as? [BridgeableValue] {
    expectEqualSequence(bridgeableValues, downcasted)
  }

  // Downcast from a nil implicitly unwrapped optional array of AnyObjects.
  wrappedCocoaBridgeableValuesIUO = nil
  expectEmpty(wrappedCocoaBridgeableValuesIUO as? [BridgeableValue])

  // Downcast from an optional array of AnyObjects.
  var wrappedCocoaBridgeableValuesOpt: [AnyObject]? = wrappedCocoaBridgeableValues
  if let downcasted = wrappedCocoaBridgeableValuesOpt as? [BridgeableValue] {
    expectEqualSequence(bridgeableValues, downcasted)
  }

  // Downcast from a nil optional array of AnyObjects.
  wrappedCocoaBridgeableValuesOpt = nil
  expectEmpty(wrappedCocoaBridgeableValuesOpt as? [BridgeableValue])
  
  testBridgeableValue(Thunks())
}

tests.test("testRoundTrip") {
  class Test : NSObject {
    @objc dynamic func call(_ array: NSArray) -> NSArray {

      let result = array as! [BridgeableValue]
      expectEqual(0, bridgeFromOperationCount)
      expectEqual(0, bridgeToOperationCount)

      // Clear out the stats before returning array
      BridgeableValue.resetStats()
      return result as NSArray
    }
  }
  
  let test = Test()
  
  let array = [
    BridgeableValue(10), BridgeableValue(20), BridgeableValue(30),
    BridgeableValue(40), BridgeableValue(50) ]
  
  BridgeableValue.resetStats()
  _ = test.call(array as NSArray)
  
  expectEqual(0, bridgeFromOperationCount)
  expectEqual(0, bridgeToOperationCount)
}

//===--- Non-bridging -----------------------------------------------------===//
// X is not bridged to Objective-C
//===----------------------------------------------------------------------===//

struct X {}

tests.test("testMutableArray") {
  let m = NSMutableArray(array: ["fu", "bar", "buzz"])
  let a = m as NSArray as! [NSString]

  // Create distinct array storage with a copy of the elements in a
  let aCopy = a.map { $0 }

  // Modify the original mutable array
  m.add("goop")

  // Check that our [NSString] is unaffected
  expectEqualSequence(aCopy, a)
}

runAllTests()
