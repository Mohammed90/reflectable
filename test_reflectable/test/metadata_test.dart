// Copyright (c) 2016, the Dart Team. All rights reserved. Use of this
// source code is governed by a BSD-style license that can be found in
// the LICENSE file.

/// Tests that metadata is preserved when the metadataCapability is present.
// TODO(sigurdm) implement: Support for metadata-annotations of arguments.

@c
library test_reflectable.test.metadata_test;

import 'package:reflectable/reflectable.dart';
import 'package:unittest/unittest.dart';

class MyReflectable extends Reflectable {
  const MyReflectable()
      : super(metadataCapability, instanceInvokeCapability,
            staticInvokeCapability, declarationsCapability, libraryCapability);
}

const myReflectable = const MyReflectable();

class MyReflectable2 extends Reflectable {
  const MyReflectable2()
      : super(instanceInvokeCapability, staticInvokeCapability);
}

const myReflectable2 = const MyReflectable2();

const b = 13;
const c = const [
  const Bar(const {"a": 14})
];
const d = true;

class K {
  static const p = 2;
}

@myReflectable
@Bar(const {
  b: deprecated,
  c: const Deprecated("tomorrow"),
  1 + 2: (d ? 3 : 4),
  identical(1, 2): "s",
  K.p: 6
})
@b
@c
class Foo {
  @Bar(const {})
  @Bar.namedConstructor(const {})
  @b
  @c
  foo() {}

  @b
  var x = 10;
}

@myReflectable2
@Bar(const {})
@Bar.namedConstructor(const {})
@b
@c
class Foo2 {
  @Bar(const {})
  @Bar.namedConstructor(const {})
  @b
  @c
  foo() {}
}

class Bar {
  final Map<Object, Object> m;
  const Bar(this.m);
  const Bar.namedConstructor(this.m);
  toString() => "Bar($m)";
}

main() {
  test("metadata on class", () {
    expect(myReflectable.reflectType(Foo).metadata, const [
      const MyReflectable(),
      const Bar(const {
        b: deprecated,
        c: const Deprecated("tomorrow"),
        3: 3,
        false: "s",
        2: 6
      }),
      13,
      const [
        const Bar(const {"a": 14})
      ]
    ]);

    ClassMirror fooMirror = myReflectable.reflectType(Foo);
    expect(fooMirror.declarations["foo"].metadata, const [
      const Bar(const {}),
      const Bar(const {}),
      13,
      const [
        const Bar(const {"a": 14})
      ]
    ]);

    expect(fooMirror.declarations["x"].metadata, [b]);

    // The synthetic accessors do not have metadata.
    expect(fooMirror.instanceMembers["x"].metadata, []);
    expect(fooMirror.instanceMembers["x="].metadata, []);

    // Test metadata on libraries
    expect(myReflectable.reflectType(Foo).owner.metadata, [c]);
  });
  test("metadata without capability", () {
    ClassMirror foo2Mirror = myReflectable2.reflectType(Foo2);
    expect(() => foo2Mirror.metadata,
        throwsA(const isInstanceOf<NoSuchCapabilityError>()));

    expect(() => foo2Mirror.declarations["foo"].metadata,
        throwsA(const isInstanceOf<NoSuchCapabilityError>()));
  });
}
