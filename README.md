# Full Deploy VPS

Skill agnóstica para automatizar deploys de produção em VPS com Docker + Traefik.

Ela foi criada para tornar o fluxo de publicação de aplicações web mais determinístico, limpo, seguro e rápido, encaixando naturalmente em pipelines de desenvolvimento agile.

## O Que Ela Faz

- Publica aplicações estáticas e dinâmicas em VPS.
- Suporta runtimes Node, Python e stacks híbridos React/Vite + FastAPI.
- Gera um plano imutável antes de qualquer alteração.
- Fixa o commit exato que será implantado.
- Sincroniza `.env` local com o VPS sem expor segredos no plano ou no comando.
- Cria e valida um container candidato isolado antes de promover para produção.
- Usa Docker + Traefik para build, roteamento, TLS e exposição pública.
- Executa rollback automático se o healthcheck público falhar.

## Filosofia

Deploy não deve depender de sorte, memória ou passos manuais frágeis.

O Full Deploy VPS transforma publicação remota em um processo reproduzível: planejar, confirmar, validar, ativar e verificar. Só depois de passar por esse fluxo a nova versão entra em produção.

## Fluxo

1. A skill detecta o perfil da aplicação.
2. Gera um plano de deploy com hash de confirmação.
3. O usuário confirma explicitamente o plano.
4. O código é clonado no commit fixado.
5. O build é executado em ambiente controlado.
6. Um container candidato é validado isoladamente.
7. A versão é promovida para produção.
8. O domínio público é verificado.
9. Em caso de falha, a versão anterior é restaurada.

## Perfis Suportados

- HTML estático.
- Vite/React estático.
- Node runtime.
- Python runtime.
- React/Vite + FastAPI.
- Dockerfile customizado do projeto.

## Objetivo

Reduzir atrito operacional, evitar deploys inconsistentes e dar previsibilidade ao ciclo de desenvolvimento, com uma camada de automação robusta para publicar aplicações reais em ambientes remotos.
