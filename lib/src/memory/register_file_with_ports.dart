// Convenience subclass of RegisterFile that exposes its input ports as
// public fields so callers holding a reference to the RF instance can
// inspect or drive the ports directly.
//
// This preserves the RegisterFile constructor semantics but stores the
// provided writePorts/readPorts as named fields `extWrites` and `extReads`.
import 'package:rohd_hcl/rohd_hcl.dart';

/// Extension of [RegisterFile] that exposes the externally provided
/// read and write ports with getters.
class RegisterFileExportedInterfaces extends RegisterFile {
  /// Exported access to connected external write ports.
  List<DataPortInterface> get writes => _extWrites;

  /// Exported access to connected external read ports.
  List<DataPortInterface> get reads => _extReads;

  /// External write ports passed into the RF constructor.
  final List<DataPortInterface> _extWrites;

  /// External read ports passed into the RF constructor.
  final List<DataPortInterface> _extReads;

  /// Constructs a new [RegisterFileExportedInterfaces] that exposes the externally
  /// supplied ports with getters.
  RegisterFileExportedInterfaces(
    super.clk,
    super.reset,
    super.writePorts,
    super.readPorts, {
    super.numEntries,
    super.name,
    bool? reserveName,
    bool? reserveDefinitionName,
    super.definitionName,
    super.resetValue,
  })  : _extWrites = writePorts,
        _extReads = readPorts,
        super(
            reserveName: reserveName ?? false,
            reserveDefinitionName: reserveDefinitionName ?? false);
}
