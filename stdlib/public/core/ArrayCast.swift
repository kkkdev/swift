//===--- ArrayCast.swift - Casts and conversions for Array ----------------===//
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
//
//  Because NSArray is effectively an [AnyObject], casting [T] -> [U]
//  is an integral part of the bridging process and these two issues
//  are handled together.
//
//===----------------------------------------------------------------------===//

/// Implements `source as! [TargetElement]`.
///
/// - Note: When SourceElement and TargetElement are both bridged verbatim, type
///   checking is deferred until elements are actually accessed.
public func _arrayForceCast<SourceElement, TargetElement>(
  _ source: Array<SourceElement>
) -> Array<TargetElement> {
  if _isClassOrObjCExistential(SourceElement.self)
  && _isClassOrObjCExistential(TargetElement.self) {
    let src = source._buffer
    if let native = src.requestNativeBuffer() {
      if native.storesOnlyElementsOfType(TargetElement.self) {
        // A native buffer that is known to store only elements of the
        // TargetElement can be used directly
        return Array(_buffer: src.cast(toBufferOf: TargetElement.self))
      }
      // Other native buffers must use deferred element type checking
      return Array(_buffer:
        src.downcast(toBufferWithDeferredTypeCheckOf: TargetElement.self))
    }
    return Array(_immutableCocoaArray: source._buffer._asCocoaArray())
  }
  return _arrayConditionalCast(source)!
}

struct UnwrapFailure : Error {}
extension Optional {
  internal func unwrappedOrError() throws -> Wrapped {
    if self == nil { throw UnwrapFailure() }
    return self.unsafelyUnwrapped
  }
}

/// Implements `source as? [TargetElement]`: convert each element of
/// `source` to a `TargetElement` and return the resulting array, or
/// return `nil` if any element fails to convert.
///
/// - Complexity: O(n), because each element must be checked.
public func _arrayConditionalCast<SourceElement, TargetElement>(
  _ source: [SourceElement]
) -> [TargetElement]? {
  return try? source.map { try ($0 as? TargetElement).unwrappedOrError() }
}
