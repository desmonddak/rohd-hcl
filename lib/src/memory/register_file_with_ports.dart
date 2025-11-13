// Convenience subclass of RegisterFile that exposes its input ports as
// public fields so callers holding a reference to the RF instance can
// inspect or drive the ports directly.
//
// This preserves the RegisterFile constructor semantics but stores the
// provided writePorts/readPorts as named fields `extWrites` and `extReads`.
import 'package:rohd_hcl/rohd_hcl.dart';

/// Experimental module that exposes the input interfaces for easier generation
/// of connecting logic.
class RegisterFileWithPorts extends RegisterFile {
  /// External write ports passed into the RF constructor.
  final List<DataPortInterface> extWrites;

  /// External read ports passed into the RF constructor.
  final List<DataPortInterface> extReads;

  /// Constructs a new [RegisterFileWithPorts] that exposes the externally
  /// supplied ports with getters.
  RegisterFileWithPorts(
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
  })  : extWrites = writePorts,
        extReads = readPorts,
        super(
            reserveName: reserveName ?? false,
            reserveDefinitionName: reserveDefinitionName ?? false);

  /// The internal cloned write ports stored inside the Memory/RegisterFile
  /// instance. These are the actual ports the RF uses internally (the
  /// base class clones the externally provided interfaces), and are useful
  /// for inspection or wiring when you need the concrete ports bound to
  /// this module instance.
  List<DataPortInterface> get internalWrites => wrPorts;

  /// The internal cloned read ports stored inside the Memory/RegisterFile
  /// instance.
  List<DataPortInterface> get internalReads => rdPorts;
}
