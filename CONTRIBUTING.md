# Contribuer

## Branches : Conventional Branch

Nous recommandons [Conventional Branch](https://conventional-branch.github.io/) pour les noms de branches.

Format:
```
<type>/<description>
```

### Types de branches
- `feature/` ou `feat/` : Nouvelle fonctionnalité (ex: `feature/add-login-page`)
- `bugfix/` ou `fix/` : Correction de bug (ex: `bugfix/fix-header-layout`)
- `hotfix/` : Correction urgente (ex: `hotfix/security-patch`)
- `ci/` : Changements CI/CD uniquement (ex: `ci/add-github-actions-workflow`)
- `chore/` : Tâches sans rapport au code (ex: `chore/update-dependencies`)

### Règles
- Utiliser uniquement des minuscules, chiffres, hyphens et dots
- Pas de hyphens/dots consécutifs, au début ou à la fin
- Clair et concis
- Optionnel : inclure le numéro de ticket (ex: `feature/issue-123-add-login`)

**Note** : Les humains ne sont pas strictement limités à cette convention, mais c'est fortement recommandé.

## Commits : Conventional Commits

Nous utilisons [Conventional Commits](https://www.conventionalcommits.org/) pour nos messages de commit.

Format:
```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Types
- `feat` : Une nouvelle fonctionnalité
- `fix` : Un correctif de bug
- `docs` : Changements de documentation
- `style` : Changements de style (formatage, points-virgules, etc.)
- `refactor` : Refactoring du code sans ajouter de feature ni corriger de bug
- `perf` : Amélioration des performances
- `test` : Ajout ou modification de tests
- `chore` : Changements de la build, dépendances, outils
- `ci` : Un changement sur la CI/CD

### Exemples
```
feat(api): add new endpoint for user authentication
fix: resolve memory leak in connection pool
docs: update README with installation instructions
```

## Pull Requests

### Titre de la PR

Le titre doit être descriptif et clair. Il peut être basé sur le nom de la branche, mais doit inclure un contexte:

Format recommandé:
```
[Type] Feature/Fix name (branch-name)
```

Ou simplement:
```
<type>: Clear description of what the PR does
```

Exemples valides:
```
feat: Add authentication middleware to API routes
fix: Resolve memory leak in connection pool
docs: Update deployment guide with new variables
```

### Body de la PR

Le body doit contenir:
- **Contexte** : Pourquoi cette PR est nécessaire
- **Changements** : Quoi a changé
- **Issues liées** : Référencer les issues fermées avec `Closes #123`
- **Tests** : Comment tester les changements

Exemple:
```
## Contexte
We needed to add rate limiting to prevent abuse of the API.

## Changements
- Added rate limiter middleware
- Configured limits per endpoint
- Added metrics tracking

## Issues liées
Closes #456

## Tests
- Run `npm run test:api` to verify endpoints
- Manual testing with more than 100 requests per minute should return 429
```

### Reviews et Conventional Comments

Utiliser [Conventional Comments](https://conventionalcomments.org/) pour les reviews :
```
<label> [decorations]: <subject>
```

Labels : `praise`, `nitpick`, `suggestion`, `issue`, `todo`, `question`, `thought`
