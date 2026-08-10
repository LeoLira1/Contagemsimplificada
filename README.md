# Contagem CAMDA

App Android para conferência física de produtos na loja CAMDA (Quirinópolis-GO).

Pega a **lista de contagem** da aba Contagem do dashboard
[`camda-estoque`](https://github.com/LeoLira1/camda-estoque) e cruza cada item
com a **posição física** cadastrada no app
[`Gondolas`](https://github.com/LeoLira1/Gondolas). O conferente vê o que
contar, onde está e quanto o sistema diz existir — e responde **OK** ou
**Divergência** ali mesmo, sem passar pelo computador.

Os três apps falam com o **mesmo banco Turso**. Não há API no meio: este app
lê e escreve nas mesmas tabelas que o dashboard.

## O card

```
GLIFOSATO 480 SL 20L  —  10432
│ ESTANTE 8
│ Posição A   ·   12 un no local
24 un                      [ ✓ OK ]  [ ⚠ ]
```

Um produto endereçado em mais de um lugar mostra o primeiro em destaque e os
demais como etiquetas (`G9·F3·A2`) logo abaixo — mandar o conferente a um só
lugar quando há dois faria a contagem sair errada por omissão.

## De onde vem cada coisa

| Na tela | Tabela | Quem alimenta |
|---|---|---|
| Nome, código, categoria, quantidade | `contagem_itens` | dashboard, ao subir planilha parcial |
| Observação / cooperado | `estoque_mestre`, `divergencias` | dashboard |
| Estante ou gôndola + posição | `estoque_localizado`, `estante_layout`, `gondola_layout` | app Gôndolas |

As posições vêm de **três** tabelas de propósito: `estoque_localizado` só tem
endereço onde alguém já contou; `estante_layout` e `gondola_layout` têm o
cadastro de onde o produto mora, mesmo sem contagem. Um produto endereçado e
nunca contado só aparece nas duas últimas — e é justamente quem mais precisa
aparecer na tela.

## O que o app grava

**OK ✓** → `contagem_itens.status = 'certa'`; se o produto estava em falta ou
sobra, volta a `ok` no `estoque_mestre` e sai da lista de divergências do
cooperado.

**Divergência** → pergunta **quantas unidades você contou** (o dashboard pede a
diferença com sinal; aqui o app calcula, porque fazer subtração de cabeça em pé
na frente da prateleira é onde nasce erro de inventário), grava a falta/sobra
em `estoque_mestre`, registra em `divergencias` + `historico_divergencias` e
marca o item como `divergencia`.

Quando já existe divergência aberta para o produto, o app mostra quem e quanto,
e deixa escolher entre **confirmar a existente** (sem criar registro novo) ou
**registrar adicional** — mesma escolha que o dashboard oferece. Sem isso, a
mesma falta entraria duas vezes e o saldo do cooperado dobraria.

O inventário cíclico se atualiza sozinho: os triggers `trig_contagem_to_cicli`
e `trig_contagem_status_ciclo`, criados pelo dashboard, disparam na mudança de
status. Por isso o app grava o `estoque_mestre` **antes** de `contagem_itens` —
assim os triggers já leem o `qtd_fisica` final.

Todos os carimbos de data são gravados em horário de Brasília, como o
dashboard faz, para a contagem não cair no dia errado do cíclico quando alguém
confere à noite.

## Sempre online, de propósito

Diferente do app Gôndolas, aqui **não** há réplica local com escrita offline:

1. A lista é remontada a cada upload de planilha. Conferir uma lista cacheada
   de ontem é pior do que não conferir.
2. Confirmar um item dispara triggers no banco. Uma escrita offline que só sobe
   depois abriria janela de conflito com o mesmo item confirmado no dashboard.

O app exige rede para trabalhar, e diz isso na cara quando ela falta.

## Usar

1. Instale o APK da [última release](../../releases/latest).
2. Na primeira abertura, informe a **URL** e o **token** do Turso — os mesmos
   do dashboard e do app das gôndolas. O app testa a conexão antes de salvar.
3. Puxe para atualizar sempre que o dashboard subir uma planilha nova.

Na barra de controles dá para alternar entre **Pendentes** e **Conferidos**, e
entre agrupar por **Categoria** (a ordem do dashboard) ou por **Local** — esta
segunda é a que segue o caminho de quem anda pela loja, conferindo um corredor
inteiro antes de ir para o próximo. A busca aceita nome, código e também
endereço: digitar `E5` filtra tudo que está na estante 5.

As credenciais ficam só no aparelho (`shared_preferences`), nunca no
repositório.

## Desenvolvimento

```bash
flutter pub get
flutter analyze
flutter test
```

O projeto Android **não** é versionado: o CI roda `flutter create` e copia a
pasta `android/`, para nenhum binário (como o `gradle-wrapper.jar`) entrar no
git — mesma escolha do repositório Gôndolas. Todo push no branch de trabalho
gera APK e publica uma release.

### `lib/enderecos.dart` é um porte, não um arquivo original

O esquema de letras e números das prateleiras (`A–F` na EDR-300, `1–72` na
Estante Parede, `A1` nos ganchos intercalados da MagnoJet…) foi portado de
`lib/models.dart` do repositório Gôndolas. **As constantes precisam continuar
idênticas às de lá:** os dois apps leem as mesmas linhas do banco, e uma
divergência manda o conferente para a prateleira errada sem erro nenhum
aparecer na tela. `test/enderecos_test.dart` trava esses casos.

### Assinatura do APK (keystore fixo)

O Android só aceita instalar uma atualização por cima se ela vier assinada com
a **mesma chave** da versão instalada. Com a chave de debug do Flutter isso
nunca acontece: ela muda a cada build, e o celular responde "App não foi
instalado".

O CI resolve isso lendo um keystore dos secrets do repositório
(`tool/configurar_assinatura.py`). **Sem os quatro secrets configurados o build
não quebra** — segue com a chave de debug e marca a release com um aviso.

Para configurar, uma vez só:

```bash
# 1. Gere o keystore na SUA máquina (PKCS#12, padrão atual do keytool).
#    Guarde este arquivo e as senhas: perdê-los significa nunca mais
#    conseguir atualizar o app por cima — só desinstalando.
keytool -genkeypair -v \
  -keystore camda-contagem.p12 -storetype PKCS12 \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias camda

# 2. Converta para base64 numa linha só.
base64 -w 0 camda-contagem.p12 > keystore.base64
```

Depois, em **Settings → Secrets and variables → Actions → New repository
secret**, crie os quatro:

| Secret | Valor |
|---|---|
| `KEYSTORE_BASE64` | conteúdo de `keystore.base64` |
| `KEY_ALIAS` | `camda` (o `-alias` usado acima) |
| `KEY_PASSWORD` | a senha da chave |
| `STORE_PASSWORD` | a senha do keystore |

O keystore é gerado localmente, e não pelo CI, de propósito: ele precisa de um
backup que **você** controle. Se existisse só dentro dos secrets do GitHub,
perder o acesso ao repositório significaria perder a capacidade de atualizar o
app para sempre.

Cada release passa a trazer o SHA-256 do certificado que assinou aquele APK —
se ele for igual entre dois builds, a atualização por cima funciona.
