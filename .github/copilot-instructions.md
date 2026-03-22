---
name: "IntegratedDynamic Infrastructure - Configuration"
description: "Conventions de projet et préférences de codage pour l'infrastructure"
---

# Instructions pour GitHub Copilot

## Onboarding

### Gestion des dépendances

Les dépendances du projet sont gérées via **mise**.

**Installation** :
```bash
mise install
```

ℹ️ **Automatique** : Une fois `mise.toml` modifié, `mise install` se lance automatiquement via un hook.

## Conventions de code

### Branches

Je dois TOUJOURS utiliser [Conventional Branch](https://conventional-branch.github.io/).

Format strict:
```
<type>/<description>
```

Types: `feature/`, `bugfix/`, `hotfix/`, `ci/`, `chore/`

Exemples:
- `feature/add-authentication-middleware`
- `bugfix/fix-memory-leak`
- `ci/add-github-actions-workflow`

Règles obligatoires:
- Minuscules, chiffres, hyphens et dots uniquement
- Pas de hyphens/dots consécutifs ou aux extrémités
- Inclure ticket number si applicable: `feature/issue-456-add-auth`

### Commits

Utiliser [Conventional Commits](https://www.conventionalcommits.org/) :
```
<type>[scope]: <description>
```

Types : `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`

### Pull Requests

**Titre** : Doit être descriptif et clair. Format recommandé avec type et description.
```
<type>: Clear description of what the PR does
```

**Body** : Contexte, changements, issues liées (via `Closes #123`), et instructions de test.

Utiliser [Conventional Comments](https://conventionalcomments.org/) pour les reviews :
```
<label> [decorations]: <subject>
```

Labels : `praise`, `nitpick`, `suggestion`, `issue`, `todo`, `question`, `thought`

Voir [CONTRIBUTING.md](../CONTRIBUTING.md) pour plus de détails.

## Structure du projet

## Technologies et frameworks

## Pratiques de développement

## Points importants à retenir
