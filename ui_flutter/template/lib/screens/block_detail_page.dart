import "package:flutter/material.dart";

import "../api/core_client.dart";
import "../utils/format.dart";
import "../widgets/block_detail_sheet.dart";

class BlockDetailPage extends StatelessWidget {
  const BlockDetailPage({
    super.key,
    required this.client,
    required this.block,
  });

  final CoreClient client;
  final BlockSummary block;

  @override
  Widget build(BuildContext context) {
    final title = "${formatHHMM(block.startTs)}–${formatHHMM(block.endTs)}";
    return Scaffold(
      appBar: AppBar(title: Text("Block $title")),
      body: SafeArea(
        child: BlockDetailSheet(
          client: client,
          block: block,
          showHeader: false,
          asStandalonePage: true,
        ),
      ),
    );
  }
}
