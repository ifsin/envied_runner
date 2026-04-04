import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:envied_generator/envied_generator.dart';
import 'package:envied_generator/src/build_options.dart';
import 'package:path/path.dart';
import 'package:source_gen/source_gen.dart';
import 'package:source_gen/src/output_helpers.dart'
    show normalizeGeneratorOutput;

class _MockBuildStep extends BuildStep {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main(List<String> args) async {
  if (args.length < 2) {
    print('Usage: dart run envied_runner:generate <env_file> <dart_file>');
    print('Example: dart run envied_runner:generate .env.dev lib/env/env.dart');
    exit(1);
  }

  final envPath = args[0];
  final dartFile = args[1];
  final fileName = basename(dartFile);

  final absolutePath = normalize(File(dartFile).absolute.path);

  final collection = AnalysisContextCollection(
    includedPaths: [absolutePath],
    resourceProvider: PhysicalResourceProvider.INSTANCE,
  );

  final context = collection.contextFor(absolutePath);
  final result = await context.currentSession.getResolvedLibrary(absolutePath);

  if (result is! ResolvedLibraryResult) {
    print('Failed to resolve $dartFile');
    exit(1);
  }

  final libraryElement = result.element;
  final libraryReader = LibraryReader(libraryElement);

  // Create the envied generator with our env path override
  final generator = EnviedGenerator(
    BuildOptions(path: envPath, override: true),
  );

  final outputs = <String>[];

  for (final element in libraryReader.allElements) {
    if (element is! ClassElement) continue;

    final annotation = generator.typeChecker.firstAnnotationOf(element);
    if (annotation == null) continue;

    final generatedStream = normalizeGeneratorOutput(
      generator.generateForAnnotatedElement(
        element,
        ConstantReader(annotation),
        _MockBuildStep(),
      ),
    );

    final generated = await generatedStream.join('\n\n');
    if (generated.isNotEmpty) {
      outputs.add(generated);
    }
  }

  if (outputs.isEmpty) {
    print('No @Envied classes found in $dartFile');
    exit(1);
  }

  final formatter = DartFormatter(
    languageVersion: libraryElement.languageVersion.effective,
  );

  final combined = outputs.join('\n\n');
  String formatted;
  try {
    formatted = formatter.format(combined);
  } catch (_) {
    formatted = combined;
  }

  final outputPath = dartFile.replaceAll('.dart', '.env.dart');
  File(outputPath).writeAsStringSync(
    '// Generated code - do not modify by hand\n\n'
    "part of '$fileName';\n\n"
    '$formatted\n',
  );

  print('Generated $outputPath from $envPath');

  await collection.dispose();
}
