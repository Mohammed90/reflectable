// (c) 2015, the Dart Team. All rights reserved. Use of this
// source code is governed by a BSD-style license that can be found in
// the LICENSE file.

library reflectable.src.transformer_implementation;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/constant.dart';
import 'package:analyzer/src/generated/element.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';
import 'package:barback/barback.dart';
import 'package:code_transformers/resolver.dart';
import "reflectable_class_constants.dart" as reflectable_class_constants;
import 'source_manager.dart';
import 'transformer_errors.dart' as errors;
import '../capability.dart';

class ReflectionWorld {
  final List<ReflectorDomain> reflectors = new List<ReflectorDomain>();
  final LibraryElement reflectableLibrary;

  ReflectionWorld(this.reflectableLibrary);

  Iterable<ReflectorDomain> reflectorsOfLibrary(LibraryElement library) {
    return reflectors.where((ReflectorDomain domain) {
      return domain.reflector.library == library;
    });
  }

  Iterable<ClassDomain> annotatedClassesOfLibrary(LibraryElement library) {
    return reflectors
        .expand((ReflectorDomain domain) => domain.annotatedClasses)
        .where((ClassDomain classDomain) {
      return classDomain.classElement.library == library;
    });
  }
}

/// Information about the program parts that can be reflected by a given
/// Reflector.
class ReflectorDomain {
  final ClassElement reflector;
  final List<ClassDomain> annotatedClasses;
  final Capabilities capabilities;

  /// Libraries that must be imported to `reflector.library`.
  final Set<LibraryElement> missingImports = new Set<LibraryElement>();

  ReflectorDomain(this.reflector, this.annotatedClasses, this.capabilities);
}

/// Information about reflectability for a given class.
class ClassDomain {
  final ClassElement classElement;
  Iterable<MethodElement> invokableMethods;
  ReflectorDomain reflectorDomain;

  ClassDomain(this.classElement, this.invokableMethods, this.reflectorDomain);
}

/// A wrapper around a list of Capabilities.
/// Supports queries about the methods supported by the set of capabilities.
class Capabilities {
  List<ReflectCapability> capabilities;
  Capabilities(this.capabilities);

  instanceMethodsFilterRegexpString() {
    if (capabilities.contains(invokeInstanceMembersCapability)) return ".*";
    if (capabilities.contains(invokeMembersCapability)) return ".*";
    return capabilities.where((ReflectCapability capability) {
      return capability is InvokeInstanceMemberCapability;
    }).map((InvokeInstanceMemberCapability capability) {
      return capability.name;
    }).join('|');
  }

  bool supportsInstanceInvoke(String methodName) {
    if (capabilities.contains(invokeInstanceMembersCapability)) return true;
    if (capabilities.contains(invokeMembersCapability)) return true;

    bool handleMetadataCapability(ReflectCapability capability) {
      if (capability is! InvokeMembersWithMetadataCapability) return false;
      // TODO(eernst): Handle InvokeMembersWithMetadataCapability
      throw new UnimplementedError();
    }
    if (capabilities.any(handleMetadataCapability)) return true;

    bool handleMembersUpToSuperCapability(ReflectCapability capability) {
      if (capability is InvokeInstanceMembersUpToSuperCapability) {
        if (capability.superType == Object) return true;
        // TODO(eernst): Handle InvokeInstanceMembersUpToSuperCapability up
        // to something non-trivial.
        throw new UnimplementedError();
      } else {
        return false;
      }
    }
    if (capabilities.any(handleMembersUpToSuperCapability)) return true;

    bool handleInstanceMemberCapability(ReflectCapability capability) {
      if (capability is InvokeInstanceMemberCapability) {
        return capability.name == methodName;
      } else {
        return false;
      }
    }
    return capabilities.any(handleInstanceMemberCapability);
  }
}

// TODO(eernst): Keep in mind, with reference to
// http://dartbug.com/21654 comment #5, that it would be very valuable
// if this transformation can interact smoothly with incremental
// compilation.  By nature, that is hard to achieve for a
// source-to-source translation scheme, but a long source-to-source
// translation step which is invoked frequently will certainly destroy
// the immediate feedback otherwise offered by incremental compilation.
// WORKAROUND: A work-around for this issue which is worth considering
// is to drop the translation entirely during most of development,
// because we will then simply work on a normal Dart program that uses
// dart:mirrors, which should have the same behavior as the translated
// program, and this could work quite well in practice, except for
// debugging which is concerned with the generated code (but that would
// ideally be an infrequent occurrence).

class TransformerImplementation {
  TransformLogger logger;
  Resolver resolver;

  static final int _antiNameClashSaltInitValue = 9238478278;
  int _antiNameClashSalt = _antiNameClashSaltInitValue;

  /// Checks whether the given [type] from the target program is "our"
  /// class [Reflectable] by looking up the static field
  /// [Reflectable.thisClassId] and checking its value (which is a 40
  /// character string computed by sha1sum on an old version of
  /// reflectable.dart).
  ///
  /// Discussion of approach: Checking that we have found the correct
  /// [Reflectable] class is crucial for correctness, and the "obvious"
  /// approach of just looking up the library and then the class with the
  /// right names using [resolver] is unsafe.  The problems are as
  /// follows: (1) Library names are not guaranteed to be unique in a
  /// given program, so we might look up a different library named
  /// reflectable.reflectable, and a class named Reflectable in there.  (2)
  /// Library URIs (which must be unique in a given program) are not known
  /// across all usage locations for reflectable.dart, so we cannot easily
  /// predict all the possible URIs that could be used to import
  /// reflectable.dart; and it would be awkward to require that all user
  /// programs must use exactly one specific URI to import
  /// reflectable.dart.  So we use [Reflectable.thisClassId] which is very
  /// unlikely to occur with the same value elsewhere by accident.
  bool _equalsClassReflectable(ClassElement type) {
    FieldElement idField = type.getField("thisClassId");
    if (idField == null || !idField.isStatic) return false;
    if (idField is ConstFieldElementImpl) {
      EvaluationResultImpl idResult = idField.evaluationResult;
      if (idResult != null) {
        return idResult.value.stringValue == reflectable_class_constants.id;
      }
      // idResult == null: analyzer/.../element.dart does not specify
      // whether this could happen, but it is surely not the right
      // class, so we fall through.
    }
    // Not a const field, cannot be the right class.
    return false;
  }

  /// Returns the ClassElement in the target program which corresponds to class
  /// [Reflectable].
  ClassElement _findReflectableClassElement(LibraryElement reflectableLibrary) {
    for (CompilationUnitElement unit in reflectableLibrary.units) {
      for (ClassElement type in unit.types) {
        if (type.name == reflectable_class_constants.name &&
            _equalsClassReflectable(type)) {
          return type;
        }
      }
    }
    // Class [Reflectable] was not found in the target program.
    return null;
  }

  /// Returns true iff [possibleSubtype] is a direct subclass of [type].
  bool _isDirectSubclassOf(InterfaceType possibleSubtype, InterfaceType type) {
    InterfaceType superclass = possibleSubtype.superclass;
    // Even if `superclass == null` (superclass of Object), the equality
    // test will produce the correct result.
    return type == superclass;
  }

  /// Returns true iff [possibleSubtype] is a subclass of [type], including the
  /// reflexive and transitive cases.
  bool _isSubclassOf(InterfaceType possibleSubtype, InterfaceType type) {
    if (possibleSubtype == type) return true;
    InterfaceType superclass = possibleSubtype.superclass;
    if (superclass == null) return false;
    return _isSubclassOf(superclass, type);
  }

  /// Returns the metadata class in [elementAnnotation] if it is an
  /// instance of a direct subclass of [focusClass], otherwise returns
  /// `null`.  Uses [errorReporter] to report an error if it is a subclass
  /// of [focusClass] which is not a direct subclass of [focusClass],
  /// because such a class is not supported as a Reflector.
  ClassElement _getReflectableAnnotation(
      ElementAnnotation elementAnnotation, ClassElement focusClass) {
    if (elementAnnotation.element == null) {
      // TODO(eernst): The documentation in
      // analyzer/lib/src/generated/element.dart does not reveal whether
      // elementAnnotation.element can ever be null. The following action
      // is based on the assumption that it means "there is no annotation
      // here anyway".
      return null;
    }

    /// Checks that the inheritance hierarchy placement of [type]
    /// conforms to the constraints relative to [classReflectable],
    /// which is intended to refer to the class Reflectable defined
    /// in package:reflectable/reflectable.dart. In case of violations,
    /// reports an error on [logger].
    bool checkInheritance(InterfaceType type, InterfaceType classReflectable) {
      if (!_isSubclassOf(type, classReflectable)) {
        // Not a subclass of [classReflectable] at all.
        return false;
      }
      if (!_isDirectSubclassOf(type, classReflectable)) {
        // Instance of [classReflectable], or of indirect subclass
        // of [classReflectable]: Not supported, report an error.
        logger.error(errors.METADATA_NOT_DIRECT_SUBCLASS,
            span: resolver.getSourceSpan(elementAnnotation.element));
        return false;
      }
      // A direct subclass of [classReflectable], all OK.
      return true;
    }

    Element element = elementAnnotation.element;
    // TODO(eernst): Currently we only handle constructor expressions
    // and simple identifiers.  May be generalized later.
    if (element is ConstructorElement) {
      bool isOk =
          checkInheritance(element.enclosingElement.type, focusClass.type);
      return isOk ? element.enclosingElement.type.element : null;
    } else if (element is PropertyAccessorElement) {
      PropertyInducingElement variable = element.variable;
      // Surprisingly, we have to use [ConstTopLevelVariableElementImpl]
      // here (or a similar type).  This is because none of the "public name"
      // types (types whose name does not end in `..Impl`) declare the getter
      // `evaluationResult`.  Another possible choice of type would be
      // [VariableElementImpl], but with that one we would have to test
      // `isConst` as well.
      if (variable is ConstTopLevelVariableElementImpl) {
        EvaluationResultImpl result = variable.evaluationResult;
        bool isOk = checkInheritance(result.value.type, focusClass.type);
        return isOk ? result.value.type.element : null;
      } else {
        // Not a const top level variable, not relevant.
        return null;
      }
    }
    // Otherwise [element] is some other construct which is not supported.
    //
    // TODO(eernst): We need to consider whether there could be some other
    // syntactic constructs that are incorrectly assumed by programmers to
    // be usable with Reflectable.  Currently, such constructs will silently
    // have no effect; it might be better to emit a diagnostic message (a
    // hint?) in order to notify the programmer that "it does not work".
    // The trade-off is that such constructs may have been written by
    // programmers who are doing something else, intentionally.  To emit a
    // diagnostic message, we must check whether there is a Reflectable
    // somewhere inside this syntactic construct, and then emit the message
    // in cases that we "consider likely to be misunderstood".
    return null;
  }

  /// Finds all the methods in the class and all super-classes.
  Iterable<MethodElement> allMethods(ClassElement classElement) {
    List<MethodElement> result = new List<MethodElement>();
    result.addAll(classElement.methods);
    classElement.allSupertypes.forEach((InterfaceType superType) {
      result.addAll(superType.methods);
    });
    return result;
  }

  Iterable<MethodElement> invocableInstanceMethods(
      ClassElement classElement, Capabilities capabilities) {
    return allMethods(classElement).where((MethodElement method) {
      MethodDeclaration methodDeclaration = method.node;
      // TODO(eernst): We currently ignore method declarations when
      // they are operators. One issue is generation of code (which
      // does not work if we go ahead naively).
      if (methodDeclaration.isOperator) return false;
      String methodName = methodDeclaration.name.name;
      return capabilities.supportsInstanceInvoke(methodName);
    });
  }

  /// Returns a [ReflectionWorld] instantiated with all the reflectors seen by
  /// [resolver] and all classes annotated by them.
  ///
  /// TODO(eernst): Make sure it works also when other packages are being
  /// used by the target program which have already been transformed by
  /// this transformer (e.g., there would be a clash on the use of
  /// reflectableClassId with values near 1000 for more than one class).
  ReflectionWorld _computeWorld(LibraryElement reflectableLibrary) {
    ReflectionWorld world = new ReflectionWorld(reflectableLibrary);
    Map<ClassElement, ReflectorDomain> domains =
        new Map<ClassElement, ReflectorDomain>();
    ClassElement focusClass = _findReflectableClassElement(reflectableLibrary);
    if (focusClass == null) {
      return null;
    }
    LibraryElement capabilityLibrary =
        resolver.getLibraryByName("reflectable.capability");
    for (LibraryElement library in resolver.libraries) {
      for (CompilationUnitElement unit in library.units) {
        for (ClassElement type in unit.types) {
          for (ElementAnnotation metadatum in type.metadata) {
            ClassElement reflector =
                _getReflectableAnnotation(metadatum, focusClass);
            if (reflector == null) continue;
            ReflectorDomain domain = domains.putIfAbsent(reflector, () {
              Capabilities capabilities =
                  _capabilitiesOf(capabilityLibrary, reflector);
              return new ReflectorDomain(
                  reflector, new List<ClassDomain>(), capabilities);
            });
            List<MethodElement> instanceMethods =
                invocableInstanceMethods(type, domain.capabilities).toList();
            domain.annotatedClasses
                .add(new ClassDomain(type, instanceMethods, domain));
          }
        }
      }
    }
    domains.values.forEach(_collectMissingImports);

    world.reflectors.addAll(domains.values.toList());
    return world;
  }

  /// Finds all the libraries of classes annotated by the `domain.reflector`,
  /// thus specifying which `import` directives we
  /// need to add during code transformation.
  /// These are added to `domain.missingImports`.
  void _collectMissingImports(ReflectorDomain domain) {
    LibraryElement metadataLibrary = domain.reflector.library;
    for (ClassDomain classData in domain.annotatedClasses) {
      LibraryElement annotatedLibrary = classData.classElement.library;
      if (metadataLibrary != annotatedLibrary) {
        domain.missingImports.add(annotatedLibrary);
      }
    }
  }

  /// Perform `replace` on the given [sourceManager] such that the
  /// URI of the import/export of `reflectableLibrary` specified by
  /// [uriReferencedElement] is replaced by the given [newUri]; it is
  /// required that `uriReferencedElement is` either an `ImportElement`
  /// or an `ExportElement`.
  void _replaceUriReferencedElement(SourceManager sourceManager,
      UriReferencedElement uriReferencedElement, String newUri) {
    // This is intended to work for imports and exports only, i.e., not
    // for compilation units. When this constraint is satisfied, `.node`
    // will return a `NamespaceDirective`.
    assert(uriReferencedElement is ImportElement ||
        uriReferencedElement is ExportElement);
    int uriStart = uriReferencedElement.uriOffset;
    if (uriStart == -1) {
      // Encountered a synthetic element.  We do not expect imports or
      // exports of reflectable to be synthetic, so we make it an error.
      throw new UnimplementedError(
          "Encountered synthetic import of reflectable");
    }
    int uriEnd = uriReferencedElement.uriEnd;
    // If we have `uriStart != -1 && uriEnd == -1` then there is a bug
    // in the implementation of [uriReferencedElement].
    assert(uriEnd != -1);

    int elementOffset = uriReferencedElement.node.offset;
    String elementType;
    if (uriReferencedElement is ExportElement) {
      elementType = "Export";
    } else if (uriReferencedElement is ImportElement) {
      elementType = "Import";
    } else {
      // Yes, we used `assert`, but that's ignored in production mode. So we
      // must still do something if we have neither an export nor an import.
      elementType = "UriReferencedElement";
    }
    sourceManager.replace(elementOffset, elementOffset,
        "// $elementType modified by the reflectable transformer:\n");
    sourceManager.replace(uriStart, uriEnd, "'$newUri'");
  }

  /// Returns the name of the given [classElement].  Note that we may have
  /// multiple classes in a program with the same name in this sense,
  /// because they can be in different libraries, and clashes may have
  /// been avoided because the classes are private, because no single
  /// library imports both, or because all importers of both use prefixes
  /// on one or both of them to resolve the name clash.  Hence, name
  /// clashes must be taken into account when using the return value.
  String _classElementName(ClassDomain classDomain) =>
      classDomain.classElement.node.name.name.toString();

  // _staticClassNamePrefixMap, _antiNameClashSaltInitValue, _antiNameClashSalt:
  // Auxiliary state used to generate names which are unlikely to clash with
  // existing names and which cannot possibly clash with each other, because they
  // contain the number [_antiNameClashSalt], which is updated each time it is
  // used.
  final Map<ClassElement, String> _staticClassNamePrefixMap =
      <ClassElement, String>{};

  /// Reset [_antiNameClashSalt] to its initial value, such that
  /// transformation of a given program can be deterministic even though
  /// the order of transformation of a set of programs may differ from
  /// between multiple runs of `pub build`.  Also reset caching data
  /// structures depending on [_antiNameClashSalt]:
  /// [_staticClassNamePrefixMap].
  void resetAntiNameClashSalt() {
    _antiNameClashSalt = _antiNameClashSaltInitValue;
    _staticClassNamePrefixMap.clear();
  }

  /// Returns the shared prefix of names of generated entities
  /// associated with [targetClass]. Uses [_antiNameClashSalt]
  /// to prevent name clashes among generated names, and to make
  /// name clashes with user-defined names unlikely.
  String _staticNamePrefix(ClassDomain targetClass) {
    String namePrefix = _staticClassNamePrefixMap[targetClass];
    if (namePrefix == null) {
      String nameOfTargetClass = _classElementName(targetClass);
      // TODO(eernst): Use the following version "with Salt" when we have
      // switched to the version of `checktransforms_test` that only checks
      // a handful of the very simplest transformations:
      //   namePrefix = "Static_${nameOfTargetClass}_${_antiNameClashSalt++}";
      // Currently we use the following version of this statement in order to
      // avoid the salt, because it breaks `checktransforms_test`:
      namePrefix = "Static_${nameOfTargetClass}";
      _staticClassNamePrefixMap[targetClass.classElement] = namePrefix;
    }
    return namePrefix;
  }

  /// Returns the name of the statically generated subclass of ClassMirror
  /// corresponding to the given [targetClass]. Uses [_antiNameClashSalt]
  /// to make name clashes unlikely.
  String _staticClassMirrorName(ClassDomain targetClass) =>
      "${_staticNamePrefix(targetClass)}_ClassMirror";

  // Returns the name of the statically generated subclass of InstanceMirror
  // corresponding to the given [targetClass]. Uses [_antiNameClashSalt]
  /// to make name clashes unlikely.
  String _staticInstanceMirrorName(ClassDomain targetClass) =>
      "${_staticNamePrefix(targetClass)}_InstanceMirror";

  static const String generatedComment = "// Generated";

  ImportElement _findLastImport(LibraryElement library) {
    if (library.imports.isNotEmpty) {
      ImportElement importElement = library.imports.lastWhere(
          (importElement) => importElement.node != null, orElse: () => null);
      if (importElement != null) {
        // Found an import element with a node (i.e., a non-synthetic one).
        return importElement;
      } else {
        // No non-synthetic imports.
        return null;
      }
    }
    // library.imports.isEmpty
    return null;
  }

  ExportElement _findFirstExport(LibraryElement library) {
    if (library.exports.isNotEmpty) {
      ExportElement exportElement = library.exports.firstWhere(
          (exportElement) => exportElement.node != null, orElse: () => null);
      if (exportElement != null) {
        // Found an export element with a node (i.e., a non-synthetic one)
        return exportElement;
      } else {
        // No non-synthetic exports.
        return null;
      }
    }
    // library.exports.isEmpty
    return null;
  }

  /// Find a suitable index for insertion of additional import directives
  /// into [targetLibrary].
  int _newImportIndex(LibraryElement targetLibrary) {
    // Index in [source] where the new import directive is inserted, we
    // use 0 as the default placement (at the front of the file), but
    // make a heroic attempt to find a better placement first.
    int index = 0;
    ImportElement importElement = _findLastImport(targetLibrary);
    if (importElement != null) {
      index = importElement.node.end;
    } else {
      // No non-synthetic import directives present.
      ExportElement exportElement = _findFirstExport(targetLibrary);
      if (exportElement != null) {
        // Put the new import before the exports
        index = exportElement.node.offset;
      } else {
        // No non-synthetic import nor export directives present.
        LibraryDirective libraryDirective =
            targetLibrary.definingCompilationUnit.node.directives.firstWhere(
                (directive) => directive is LibraryDirective,
                orElse: () => null);
        if (libraryDirective != null) {
          // Put the new import after the library name directive.
          index = libraryDirective.end;
        } else {
          // No library directive either, keep index == 0.
        }
      }
    }
    return index;
  }

  /// Transform all imports of [reflectableLibrary] to import the thin
  /// outline version (`static_reflectable.dart`), such that we do not
  /// indirectly import `dart:mirrors`.  Remove all exports of
  /// [reflectableLibrary] and emit a diagnostic message about the fact
  /// that such an import was encountered (and it violates the constraints
  /// of this package, and hence we must remove it).  All the operations
  /// are using [targetLibrary] to find the source code offsets, and using
  /// [sourceManager] to actually modify the source code.  We require that
  /// there is an import which has no `show` and no `hide` clause (this is
  /// a potentially temporary restriction, we may implement support for
  /// more cases later on, but for now we just prohibit `show` and `hide`).
  /// The returned value is the [PrefixElement] that is used to give
  /// [reflectableLibrary] a prefix; `null` is returned if there is
  /// no such prefix.
  PrefixElement _transformSourceDirectives(LibraryElement reflectableLibrary,
      LibraryElement targetLibrary, SourceManager sourceManager) {
    List<ImportElement> editedImports = <ImportElement>[];

    void replaceUriOfReflectable(UriReferencedElement element) {
      _replaceUriReferencedElement(sourceManager, element,
          "package:reflectable/static_reflectable.dart");
      if (element is ImportElement) editedImports.add(element);
    }

    // Exemption: We do not transform 'reflectable_implementation.dart'.
    if ("$targetLibrary" == "reflectable.src.reflectable_implementation") {
      return null;
    }

    // Transform all imports and exports of reflectable.
    targetLibrary.imports
        .where((element) => element.importedLibrary == reflectableLibrary)
        .forEach(replaceUriOfReflectable);
    targetLibrary.exports
        .where((element) => element.exportedLibrary == reflectableLibrary)
        .forEach(replaceUriOfReflectable);

    // If [reflectableLibrary] is never imported then it has no prefix.
    if (editedImports.isEmpty) return null;

    bool isOK(ImportElement importElement) {
      // We do not support a deferred load of Reflectable.
      if (importElement.isDeferred) {
        logger.error(errors.LIBRARY_UNSUPPORTED_DEFERRED,
            span: resolver.getSourceSpan(editedImports[0]));
        return false;
      }
      // We do not currently support `show` nor `hide` clauses,
      // otherwise this one is OK.
      if (importElement.combinators.isEmpty) return true;
      for (NamespaceCombinator combinator in importElement.combinators) {
        if (combinator is HideElementCombinator) {
          logger.error(errors.LIBRARY_UNSUPPORTED_HIDE,
              span: resolver.getSourceSpan(editedImports[0]));
        }
        assert(combinator is ShowElementCombinator);
        logger.error(errors.LIBRARY_UNSUPPORTED_SHOW,
            span: resolver.getSourceSpan(editedImports[0]));
      }
      return false;
    }

    // Check the imports, report problems with them if any, and try
    // to select the prefix of a good import to return.  If no good
    // imports are found we return `null`.
    PrefixElement goodPrefix = null;
    for (ImportElement importElement in editedImports) {
      if (isOK(importElement)) goodPrefix = importElement.prefix;
    }
    return goodPrefix;
  }

  /// Transform the given [reflector] by adding features needed to
  /// implement the abstract methods in Reflectable from the library
  /// `static_reflectable.dart`.  Use [sourceManager] to perform the
  /// actual source code modification.  The [annotatedClasses] is the
  /// set of Reflectable annotated class whose metadata includes an
  /// instance of the reflector, i.e., the set of classes whose
  /// instances [reflector] must provide reflection for.
  void _transformReflectorClass(ReflectorDomain reflector,
      SourceManager sourceManager, PrefixElement prefixElement) {
    // A ClassElement can be associated with an [EnumDeclaration], but
    // this is not supported for a Reflector.
    if (reflector.reflector.node is EnumDeclaration) {
      logger.error(errors.IS_ENUM,
          span: resolver.getSourceSpan(reflector.reflector));
    }
    // Otherwise it is a ClassDeclaration.
    ClassDeclaration classDeclaration = reflector.reflector.node;
    int insertionIndex = classDeclaration.rightBracket.offset;

    // Now insert generated material at insertionIndex.

    void insert(String code) {
      sourceManager.insert(insertionIndex, "$code\n");
    }

    String reflectCaseOfClass(ClassDomain classDomain) => """
    if (reflectee.runtimeType == ${_classElementName(classDomain)}) {
      return new ${_staticInstanceMirrorName(classDomain)}(reflectee);
    }
""";

    String reflectCases = ""; // Accumulates the body of the `reflect` method.

    // In front of all the generated material, indicate that it is generated.
    insert("  $generatedComment: Rest of class");

    // Add each supported case to [reflectCases].
    reflector.annotatedClasses.forEach((ClassDomain annotatedClass) {
      reflectCases += reflectCaseOfClass(annotatedClass);
    });
    reflectCases += "    throw new "
        "UnimplementedError(\"`reflect` on unexpected object '\$reflectee'\");\n";

    // Add the `reflect` method to [metadataClass].
    String prefix = prefixElement == null ? "" : "${prefixElement.name}.";
    insert("  ${prefix}InstanceMirror "
        "reflect(Object reflectee) {\n$reflectCases  }");
    // Add failure case to [reflectCases]: No matching classes, so the
    // user is asking for a kind of reflection that was not requested,
    // which is a runtime error.
    // TODO(eernst): Should use the Reflectable specific exception that Sigurd
    // introduced in a not-yet-landed CL.
  }

  /// Returns the source code for the reflection free subclass of
  /// [ClassMirror] which is specialized for a `reflectedType` which
  /// is the class modeled by [classElement].
  String _staticClassMirrorCode(ClassDomain classDomain) {
    return """
class ${_staticClassMirrorName(classDomain)} extends ClassMirrorUnimpl {
}
""";
  }

  /// Perform some very simple steps that are consistent with Dart
  /// semantics for the evaluation of constant expressions, such that
  /// information about the value of a given `const` variable can be
  /// obtained.  It is intended to help recognizing values of type
  /// [ReflectCapability], so we only cover cases needed for that.
  /// In particular, we cover lookup (e.g., with `const x = e` we can
  /// see that the value of `x` is `e`, and that step may be repeated
  /// if `e` is an [Identifier], or in general if it has a shape that
  /// is covered); similarly, `C.y` is evaluated to `42` if `C` is a
  /// class containing a declaration like `static const y = 42`. We do
  /// not perform any kind of arithmetic simplification.
  ///
  /// [context] is for error-reporting
  Expression _constEvaluate(Expression expression) {
    // [Identifier] can be [PrefixedIdentifier] and [SimpleIdentifier]
    // (and [LibraryIdentifier], but that is only used in [PartOfDirective],
    // so even when we use a library prefix like in `myLibrary.MyClass` it
    // will be a [PrefixedIdentifier] containing two [SimpleIdentifier]s).
    if (expression is SimpleIdentifier) {
      if (expression.staticElement is PropertyAccessorElement) {
        PropertyAccessorElement propertyAccessor = expression.staticElement;
        PropertyInducingElement variable = propertyAccessor.variable;
        // We expect to be called only on `const` expressions.
        if (!variable.isConst) {
          logger.error(errors.SUPER_ARGUMENT_NON_CONST,
              span: resolver.getSourceSpan(expression.staticElement));
        }
        VariableDeclaration variableDeclaration = variable.node;
        return _constEvaluate(variableDeclaration.initializer);
      }
    }
    if (expression is PrefixedIdentifier) {
      SimpleIdentifier simpleIdentifier = expression.identifier;
      if (simpleIdentifier.staticElement is PropertyAccessorElement) {
        PropertyAccessorElement propertyAccessor =
            simpleIdentifier.staticElement;
        PropertyInducingElement variable = propertyAccessor.variable;
        // We expect to be called only on `const` expressions.
        if (!variable.isConst) {
          logger.error(errors.SUPER_ARGUMENT_NON_CONST,
              span: resolver.getSourceSpan(expression.staticElement));
        }
        VariableDeclaration variableDeclaration = variable.node;
        return _constEvaluate(variableDeclaration.initializer);
      }
    }
    // No evaluation steps succeeded, return [expression] unchanged.
    return expression;
  }

  /// Returns the [ReflectCapability] denoted by the given [initializer].
  ReflectCapability _capabilityOfExpression(
      LibraryElement capabilityLibrary, Expression expression) {
    Expression evaluatedExpression = _constEvaluate(expression);

    DartType dartType = evaluatedExpression.bestType;
    // The AST must have been resolved at this point.
    assert(dartType != null);

    // We insist that the type must be a class, and we insist that it must
    // be in the given `capabilityLibrary` (because we could never know
    // how to interpret the meaning of a user-written capability class, so
    // users cannot write their own capability classes).
    if (dartType.element is! ClassElement) {
      logger.error(errors.applyTemplate(errors.SUPER_ARGUMENT_NON_CLASS, {
        "type": dartType.displayName
      }), span: resolver.getSourceSpan(dartType.element));
    }
    ClassElement classElement = dartType.element;
    if (classElement.library != capabilityLibrary) {
      logger.error(errors.applyTemplate(errors.SUPER_ARGUMENT_WRONG_LIBRARY, {
        "library": capabilityLibrary,
        "element": classElement
      }), span: resolver.getSourceSpan(classElement));
    }
    switch (classElement.name) {
      case "_InvokeMembersCapability":
        return invokeMembersCapability;
      case "InvokeMembersWithMetadataCapability":
        throw new UnimplementedError("$classElement not yet supported");
      case "InvokeInstanceMembersUpToSuperCapability":
        throw new UnimplementedError("$classElement not yet supported");
      case "_InvokeStaticMembersCapability":
        return invokeStaticMembersCapability;
      case "InvokeInstanceMemberCapability":
        throw new UnimplementedError("$classElement not yet supported");
      case "InvokeStaticMemberCapability":
        throw new UnimplementedError("$classElement not yet supported");
      default:
        throw new UnimplementedError("Unexpected capability $classElement");
    }
  }

  /// Returns the list of Capabilities given given as a superinitializer by the
  /// reflector.
  Capabilities _capabilitiesOf(
      LibraryElement capabilityLibrary, ClassElement reflector) {
    List<ConstructorElement> constructors = reflector.constructors;
    // The `super()` arguments must be unique, so there must be 1 constructor.
    assert(constructors.length == 1);
    ConstructorElement constructorElement = constructors[0];
    // It can only be a const constructor, because this class has been
    // used for metadata; it is a bug in the transformer if not.
    // It must also be a default constructor.
    assert(constructorElement.isConst);
    // TODO(eernst): Ensure that some other location in this transformer
    // checks that the metadataClass constructor is indeed a default
    // constructor, such that this can be a mere assertion rather than
    // a user-oriented error report.
    assert(constructorElement.isDefaultConstructor);
    NodeList<ConstructorInitializer> initializers =
        constructorElement.node.initializers;
    // We insist that the initializer is exactly one element, a `super(<_>[])`.
    // TODO(eernst): Ensure that this has already been checked and met with a
    // user-oriented error report.
    assert(initializers.length == 1);
    SuperConstructorInvocation superInvocation = initializers[0];
    assert(superInvocation.constructorName == null);
    NodeList<Expression> arguments = superInvocation.argumentList.arguments;
    assert(arguments.length == 1);
    ListLiteral listLiteral = arguments[0];
    NodeList<Expression> expressions = listLiteral.elements;

    ReflectCapability capabilityOfExpression(Expression expression) =>
        _capabilityOfExpression(capabilityLibrary, expression);

    return new Capabilities(expressions.map(capabilityOfExpression).toList());
  }

  /// Returns a [String] containing generated code for the `invoke`
  /// method of the static `InstanceMirror` class corresponding to
  /// the given [classElement], bounded by the permissions given
  /// in [capabilities].

  String _staticInstanceMirrorInvokeCode(ClassDomain classDomain) {
    String invokeCode = """
  Object invoke(String memberName,
                List positionalArguments,
                [Map<Symbol, dynamic> namedArguments]) {
""";

    for (MethodElement methodElement in classDomain.invokableMethods) {
      String methodName = methodElement.name;
      if (true) {
        invokeCode += """
    if (memberName == '$methodName') {
      return Function.apply(
          reflectee.$methodName,
          positionalArguments, namedArguments);
    }
""";
      }
    }
    // Handle the cases where permission is given even though there is
    // no corresponding method. One case is where _all_ methods can be
    // invoked. Another case is when the user has specified a name
    // `"foo"` and a Reflectable metadata value @reflector allowing
    // for invocation of `foo`, and then attached @reflector to a
    // class that does not define nor inherit any method `foo`.  In these
    // cases we invoke `noSuchMethod`.
    // We have the capability to invoke _all_ methods, and since the
    // requested one does not fit, it should give rise to an invocation
    // of `noSuchMethod`.
    // TODO(eernst): Cf. the problem mentioned below in relation to the
    // invocation of `noSuchMethod`: It might be a good intermediate
    // solution to create our own implementation of Invocation holding
    // the information mentioned below; it would not be able to support
    // `delegate`, but for a broad range of purposes it might still be
    // useful.
    // Even if we make our own class, we would have to have a table to construct
    // the symbol from the string.
    invokeCode += """
    // TODO(eernst, sigurdm): Create an instance of [Invocation] in user code.
    if (instanceMethodFilter.hasMatch(memberName)) {
      throw new UnimplementedError('Should call noSuchMethod');
    }
    throw new NoSuchInvokeCapabilityError(
        reflectee, memberName, positionalArguments, namedArguments);
  }
""";
    return invokeCode;
  }

  String instanceMethodFilter(Capabilities capabilities) {
    String r = capabilities.instanceMethodsFilterRegexpString();
    return """
  RegExp instanceMethodFilter = new RegExp(r"$r");
""";
  }

  /// Returns the source code for the reflection free subclass of
  /// [InstanceMirror] which is specialized for a `reflectee` which
  /// is an instance of the class modeled by [classElement].  The
  /// generated code will provide support as specified by
  /// [capabilities].
  String _staticInstanceMirrorCode(ClassDomain classDomain) {
    // The `rest` of the code is the entire body of the static mirror class,
    // except for the declaration of `reflectee`, and a constructor.
    String rest = "";
    rest += instanceMethodFilter(classDomain.reflectorDomain.capabilities);
    rest += _staticInstanceMirrorInvokeCode(classDomain);
    // TODO(eernst): add code for other mirror methods than `invoke`.
    return """
class ${_staticInstanceMirrorName(classDomain)} extends InstanceMirrorUnimpl {
  final ${_classElementName(classDomain)} reflectee;
  ${_staticInstanceMirrorName(classDomain)}(this.reflectee);
$rest}
""";
  }

  /// Returns the result of transforming the given [source] code, which is
  /// assumed to be the contents of the file associated with the
  /// [targetLibrary], which is the library currently being transformed.
  /// [reflectableClasses] models the define/use relation where
  /// reflector classes declare material for use as metadata
  /// and annotated classes use that material.
  /// [libraryToAssetMap] is used in the generation of `import` directives
  /// that enable reflector classes to see static mirror
  /// classes that it must be able to `reflect` which are declared in
  /// other libraries; [missingImports] lists the required imports which
  /// are not already present, i.e., the ones that must be added.
  /// [reflectableLibrary] is assumed to be the library that declares the
  /// class [Reflectable].
  ///
  /// TODO(eernst): The transformation has only been implemented
  /// partially at this time.
  ///
  /// TODO(eernst): Note that this function uses instances of [AstNode]
  /// and [Token] to get the correct offset into the [source] of specific
  /// constructs in the code.  This is potentially costly, because this
  /// (intermediate) parsing related information may have been evicted
  /// since parsing, and the source code will then be parsed again.
  /// However, we do not have an alternative unless we want to parse
  /// everything ourselves.  But it would be useful to be able to give
  /// barback a hint that this information should preferably be preserved.
  String _transformSource(
      ReflectionWorld world, LibraryElement targetLibrary, String source) {

    // Used to manage replacements of code snippets by other code snippets
    // in [source].
    SourceManager sourceManager = new SourceManager(source);
    sourceManager.insert(
        0, "// This file has been transformed by reflectable.\n");

    // Used to accumulate generated classes, maps, etc.
    String generatedSource = "";

    List<ClassDomain> reflectableClasses =
        world.annotatedClassesOfLibrary(targetLibrary).toList();

    // Transform selected existing elements in [targetLibrary].
    PrefixElement prefixElement = _transformSourceDirectives(
        world.reflectableLibrary, targetLibrary, sourceManager);
    world.reflectorsOfLibrary(targetLibrary).forEach((ReflectorDomain domain) {
      _transformReflectorClass(domain, sourceManager, prefixElement);
    });

    for (ClassDomain classDomain in reflectableClasses) {
      // Generate static mirror classes.
      generatedSource += _staticClassMirrorCode(classDomain) +
          "\n" +
          _staticInstanceMirrorCode(classDomain);
    }

    // If needed, add an import such that generated classes can see their
    // superclasses.  Note that we make no attempt at following the style guide,
    // e.g., by keeping the imports sorted.  Also add imports such that each
    // reflector class can see all its classes annotated with it
    // (such that the implementation of `reflect` etc. will work).
    String newImport = generatedSource.length == 0
        ? ""
        : "\nimport 'package:reflectable/src/mirrors_unimpl.dart';";
    AssetId targetId = resolver.getSourceAssetId(targetLibrary);
    for (ReflectorDomain domain in world.reflectors) {
      if (domain.reflector.library == targetLibrary) {
        for (LibraryElement importToAdd in domain.missingImports) {
          Uri importUri = resolver.getImportUri(importToAdd, from: targetId);
          newImport += "\nimport '$importUri';";
        }
      }
    }

    if (!newImport.isEmpty) {
      // Insert the import directive at the chosen location.
      int newImportIndex = _newImportIndex(targetLibrary);
      sourceManager.insert(newImportIndex, newImport);
    }
    return generatedSource.length == 0
        ? sourceManager.source
        : "${sourceManager.source}\n"
        "$generatedComment: Rest of file\n\n"
        "$generatedSource";
  }

  /// Performs the transformation which eliminates all imports of
  /// `package:reflectable/reflectable.dart` and instead provides a set of
  /// statically generated mirror classes.
  Future apply(
      AggregateTransform aggregateTransform, List<String> entryPoints) async {
    logger = aggregateTransform.logger;
    // The type argument in the return type is omitted because the
    // documentation on barback and on transformers do not specify it.
    Resolvers resolvers = new Resolvers(dartSdkDirectory);

    List<Asset> assets = await aggregateTransform.primaryInputs.toList();

    if (assets.isEmpty) {
      // It is a warning, not an error, to have nothing to transform.
      logger.warning("Warning: Nothing to transform");
      // Terminate with a non-failing status code to the OS.
      exit(0);
    }

    for (String entryPoint in entryPoints) {
      // Find the asset corresponding to [entryPoint]
      Asset entryPointAsset = assets.firstWhere(
          (Asset asset) => asset.id.path.endsWith(entryPoint),
          orElse: () => null);
      if (entryPointAsset == null) {
        aggregateTransform.logger
            .warning("Error: Missing entry point: $entryPoint");
        continue;
      }
      Transform wrappedTransform =
          new AggregateTransformWrapper(aggregateTransform, entryPointAsset);
      resetAntiNameClashSalt(); // Each entry point has a closed world.

      resolver = await resolvers.get(wrappedTransform);
      LibraryElement reflectableLibrary =
          resolver.getLibraryByName("reflectable.reflectable");
      if (reflectableLibrary == null) {
        // Stop and do not consumePrimary, i.e., let the original source
        // pass through without changes.
        continue;
      }
      ReflectionWorld world = _computeWorld(reflectableLibrary);
      if (world == null) continue;
      // An entry `assetId -> entryPoint` in this map means that `entryPoint`
      // has been transforming `assetId`.
      // This is only for purposes of better diagnostic messages.
      Map<AssetId, String> transformedViaEntryPoint =
          new Map<AssetId, String>();

      Map<LibraryElement, String> libraryPaths =
          new Map<LibraryElement, String>();

      for (Asset asset in assets) {
        LibraryElement targetLibrary = resolver.getLibrary(asset.id);
        libraryPaths[targetLibrary] = asset.id.path;
      }
      for (Asset asset in assets) {
        LibraryElement targetLibrary = resolver.getLibrary(asset.id);
        if (targetLibrary == null) continue;

        List<ReflectorDomain> reflectablesInLibary =
            world.reflectorsOfLibrary(targetLibrary).toList();

        if (reflectablesInLibary.isNotEmpty) {
          if (transformedViaEntryPoint.containsKey(asset.id)) {
            // It is not safe to transform a library that contains a reflector
            // relative to multiple entry points, because each
            // entry point defines a set of libraries which amounts to the
            // complete program, and different sets of libraries correspond to
            // potentially different sets of static mirror classes as well as
            // potentially different sets of added import directives. Hence, we
            // must reject the transformation in cases where there is such a
            // clash.
            //
            // TODO(eernst): It would actually be safe to allow for multiple
            // transformations of the same library done relative to different
            // entry points _if_ the result of those transformations were the
            // same (for instance, if both of them left that library unchanged)
            // but we do not currently detect this case. This means that we
            // might be able to allow for the transformation of more packages
            // than the ones that we accept now, that is, it is a safe future
            // enhancement to detect such a case and allow it.
            String previousEntryPoint = transformedViaEntryPoint[asset.id];

            aggregateTransform.logger.error(
                "Error: $asset is transformed twice, "
                " both via $entryPoint and $previousEntryPoint.");
            continue;
          }
          transformedViaEntryPoint[asset.id] = entryPoint;
        }
        String source = await asset.readAsString();
        String transformedSource =
            _transformSource(world, targetLibrary, source);
        // Transform user provided code.
        aggregateTransform.consumePrimary(asset.id);
        wrappedTransform
            .addOutput(new Asset.fromString(asset.id, transformedSource));
      }
      resolver.release();
    }
  }
}

/// Wrapper of `AggregateTransform` of type `Transform`, allowing us to
/// get a `Resolver` for a given `AggregateTransform` with a given
/// selection of a primary entry point.
/// TODO(eernst): We will just use this temporarily; code_transformers
/// may be enhanced to support a variant of Resolvers.get that takes an
/// [AggregateTransform] and an [Asset] rather than a [Transform], in
/// which case we can drop this class and use that method.
class AggregateTransformWrapper implements Transform {
  final AggregateTransform _aggregateTransform;
  final Asset primaryInput;
  AggregateTransformWrapper(this._aggregateTransform, this.primaryInput);
  TransformLogger get logger => _aggregateTransform.logger;
  Future<Asset> getInput(AssetId id) => _aggregateTransform.getInput(id);
  Future<String> readInputAsString(AssetId id, {Encoding encoding}) {
    return _aggregateTransform.readInputAsString(id, encoding: encoding);
  }
  Stream<List<int>> readInput(AssetId id) => _aggregateTransform.readInput(id);
  Future<bool> hasInput(AssetId id) => _aggregateTransform.hasInput(id);
  void addOutput(Asset output) => _aggregateTransform.addOutput(output);
  void consumePrimary() => _aggregateTransform.consumePrimary(primaryInput.id);
}
