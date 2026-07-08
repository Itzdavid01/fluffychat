// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class TophCallPage extends StatelessWidget {
  final String roomId;

  const TophCallPage({super.key, required this.roomId});

  @override
  Widget build(BuildContext context) {
    final room = Matrix.of(context).client.getRoomById(roomId);
    if (room == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Toph Call Mode')),
        body: const Center(
          child: Text('Room not found. You may no longer be in this chat.'),
        ),
      );
    }

    final displayName = room.getLocalizedDisplayname();

    return Scaffold(
      appBar: AppBar(title: const Text('Toph Call Mode')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              displayName,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              roomId,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 48),
            IconButton(
              iconSize: 96,
              onPressed: null, // placeholder — not wired to STT yet
              icon: const Icon(Icons.mic),
            ),
            const SizedBox(height: 16),
            const Text(
              'Idle',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 48),
            ElevatedButton.icon(
              onPressed: () => context.go('/rooms/$roomId'),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back to chat'),
            ),
          ],
        ),
      ),
    );
  }
}
