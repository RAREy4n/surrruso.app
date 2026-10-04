import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rede_apoio/api.dart';

void main() {
  group('TrustedContact', () {
    test('normaliza telefones brasileiros para formato internacional', () {
      expect(TrustedContact.normalizarTelefoneBr('(41) 99999-8888'), '5541999998888');
      expect(TrustedContact.normalizarTelefoneBr('041 99999 8888'), '5541999998888');
      expect(TrustedContact.normalizarTelefoneBr('+55 41 99999-8888'), '5541999998888');
      expect(TrustedContact.normalizarTelefoneBr('(41) 3221-2701'), '554132212701');
    });

    test('rejeita telefones inválidos', () {
      expect(TrustedContact.normalizarTelefoneBr('190'), isNull);
      expect(TrustedContact.normalizarTelefoneBr('9999-8888'), isNull);
      expect(TrustedContact.normalizarTelefoneBr('(41) 09999-8888'), isNull);
      expect(TrustedContact.fromInput(name: 'A', phone: '(41) 99999-8888'), isNull);
    });

    test('formata para exibição e serializa', () {
      final c = TrustedContact.fromInput(name: ' Mãe ', phone: '41999998888')!;
      expect(c.name, 'Mãe');
      expect(c.formattedPhone, '(41) 99999-8888');
      expect(c.dialNumber, '+5541999998888');
      final copia = TrustedContact.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
      expect(copia.phone, c.phone);
    });
  });

  group('AppContent (pacote offline embutido)', () {
    late AppContent conteudo;

    setUpAll(() {
      final texto = File(AppContentRepository.assetEmbutido).readAsStringSync();
      conteudo = AppContent.fromJson(
        jsonDecode(texto) as Map<String, dynamic>,
        ContentOrigin.embutido,
      );
    });

    test('tem os canais essenciais, com 190 como emergência principal', () {
      final telefones = conteudo.emergencyChannels.map((c) => c.phone).toList();
      expect(telefones, containsAll(['190', '180']));
      expect(conteudo.primaryEmergency?.phone, '190');
      final ligue180 = conteudo.emergencyChannels.firstWhere((c) => c.phone == '180');
      expect(ligue180.whatsapp, isNotNull);
    });

    test('agrupa categorias em chips de filtro', () {
      expect(conteudo.filterGroups.keys, containsAll(['delegacias', 'acolhimento', 'juridico', 'saude']));
      expect(conteudo.categoriesOfGroup('delegacias'), containsAll(['delegacia_mulher', 'delegacia_comum']));
      expect(conteudo.institutionCategories.any((c) => c.id == 'casa_abrigo'), isFalse);
    });

    test('traz os guias de direitos ordenados por prioridade', () {
      expect(conteudo.guides, isNotEmpty);
      expect(conteudo.guides.first.slug, 'emergencia');
      expect(conteudo.guideBySlug('plano-de-seguranca'), isNotNull);
      for (var i = 1; i < conteudo.guides.length; i++) {
        expect(conteudo.guides[i].priority, lessThanOrEqualTo(conteudo.guides[i - 1].priority));
      }
    });
  });

  group('LocationShareSession', () {
    test('lê a resposta da RPC e monta o link com o token após #', () {
      final s = LocationShareSession.fromJson({
        'share_id': 'b3f1c2d4-0000-0000-0000-000000000000',
        'publisher_token': 'segredo',
        'viewer_token': 'abc123',
        'expires_at': DateTime.now().add(const Duration(minutes: 30)).toUtc().toIso8601String(),
      });
      expect(s.viewerUrl('https://exemplo.org/acompanhar'), 'https://exemplo.org/acompanhar#t=abc123');
      expect(s.viewerUrl('https://exemplo.org/acompanhar'), isNot(contains('segredo')));
      expect(s.isExpired, isFalse);
      expect(s.remaining.inMinutes, inInclusiveRange(28, 30));
    });
  });

  group('ContactMessenger', () {
    test('mensagens contêm o link e a duração', () {
      expect(ContactMessenger.mensagemAcompanhamento('https://x/acompanhar#t=1', 30), contains('30 minutos'));
      expect(
        ContactMessenger.mensagemAcompanhamento(
          'https://x/acompanhar#t=1',
          30,
          endereco: 'Rua XV de Novembro, 123 · Centro, Curitiba',
        ),
        allOf([
          contains('30 minutos'),
          contains('📍 Rua XV de Novembro, 123 · Centro, Curitiba'),
        ]),
      );
      expect(ContactMessenger.mensagemLocalizacaoAtual(-25.4, -49.2), contains('query=-25.4,-49.2'));
    });
  });
}
