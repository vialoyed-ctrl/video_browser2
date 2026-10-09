/// PornHub 登录表单（供订阅 / 收藏 Tab 在未登录时展示）。
///
/// 用户指定的四个 Tab 里没有独立的「我的」页，所以登录入口放在这两个
/// 需要登录的版面内部，未登录时就地展示表单，而不是跳去别处。
library;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../pornhub_controller.dart';

class PornHubLoginForm extends StatelessWidget {
  const PornHubLoginForm({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ctrl = PornHubController.to;
    final email = TextEditingController();
    final password = TextEditingController();
    final cookie = TextEditingController();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: <Widget>[
        Center(
          child: Column(
            children: <Widget>[
              Icon(
                Icons.lock_person_outlined,
                size: 52,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 10),
              Text(
                '登录 PornHub',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '登录后可查看订阅与收藏',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '邮箱',
            prefixIcon: Icon(Icons.alternate_email_rounded),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: password,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: '密码',
            prefixIcon: Icon(Icons.lock_outline_rounded),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 16),
        Obx(() {
          final error = ctrl.loginError.value;
          if (error == null) return const SizedBox.shrink();
          return Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        Obx(
          () => FilledButton.icon(
            onPressed: ctrl.isLoggingIn.value
                ? null
                : () async {
                    FocusScope.of(context).unfocus();
                    final ok = await ctrl.login(email.text, password.text);
                    if (ok) password.clear();
                  },
            icon: ctrl.isLoggingIn.value
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login_rounded),
            label: Text(ctrl.isLoggingIn.value ? '登录中…' : '登录'),
          ),
        ),
        const SizedBox(height: 22),
        const Divider(),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            '改用 Cookie 登录（兜底）',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '官网若启用验证码/二次验证，原生登录会失败，此时用这个',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          children: <Widget>[
            TextField(
              controller: cookie,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: '粘贴浏览器里的 Cookie 串：name=value; name2=value2',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: () async {
                  FocusScope.of(context).unfocus();
                  await ctrl.importCookies(cookie.text);
                },
                child: const Text('用 Cookie 登录'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
