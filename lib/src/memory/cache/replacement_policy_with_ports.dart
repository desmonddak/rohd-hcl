// Auto-generated subclass to expose external and internal port lists for
// ReplacementPolicy

import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:rohd_hcl/src/memory/cache/replacement_policy.dart';

/// A small wrapper around [ReplacementPolicy] that preserves the original
/// external port lists passed into the constructor (`extHits`, `extAllocs`,
/// `extInvalidates`) and exposes the internally cloned port lists via getters
/// (`internalHits`, `internalAllocs`, `internalInvalidates`).
class ReplacementPolicyWithPorts extends ReplacementPolicy {
  /// The external lists provided by the caller.
  // final List<AccessInterface> extHits;
  // final List<AccessInterface> extAllocs;
  // final List<AccessInterface> extInvalidates;

  ReplacementPolicyWithPorts(
    super.clk,
    super.reset,
    super.hits,
    super.allocs,
    super.invalidates, {
    super.ways,
    super.name = 'replacement',
    bool? reserveName,
    bool? reserveDefinitionName,
    super.definitionName,
  }) :
        //  extHits = hits,
        //       extAllocs = allocs,
        //       extInvalidates = invalidates,
        super(
            reserveName: reserveName ?? false,
            reserveDefinitionName: reserveDefinitionName ?? false);

  /// The internal cloned hits interfaces used by the module.
  @override
  List<AccessInterface> get internalHits => hits;

  /// The internal cloned miss/alloc interfaces used by the module.
  @override
  List<AccessInterface> get internalAllocs => allocs;

  /// The internal cloned invalidate interfaces used by the module.
  @override
  List<AccessInterface> get internalInvalidates => invalidates;
}
