# Expo Web Setup — pnpm Monorepo Configuration
> Sub-file of `feature-slice` skill. Read when creating or configuring `apps/mobile`
> for the first time, or when diagnosing Metro/web bundling failures.

---

## Mandatory configuration — Expo Web in pnpm monorepo

Apply **all** items below when creating `apps/mobile`. Any missing item causes bundling failure on web.

### 1. pnpm workspace configuration (monorepo root)

**`.npmrc`:**
```
shamefully-hoist=true
```
Without this, Metro cannot find transitive dependencies from the pnpm virtual store.

**`pnpm-workspace.yaml`** — pnpm 11+ blocks build scripts for security. Add `allowBuilds` for packages that need postinstall:
```yaml
packages:
  - 'apps/*'
  - 'packages/*'
allowBuilds:
  '@nestjs/core': true
  esbuild: true
```

The `pnpm` field in `package.json` was deprecated in pnpm 11 — do not use it to configure builds.
Without `allowBuilds`, pnpm prints `[ERR_PNPM_IGNORED_BUILDS]` and postinstall scripts do not run.

### 2. `package.json` — required versions

```json
{
  "main": "expo-router/entry",
  "dependencies": {
    "react":     "19.1.0",
    "react-dom": "19.1.0",
    "react-native-web": "~0.21.2",
    "zustand": "^4.5.5"
  },
  "devDependencies": {
    "babel-plugin-transform-import-meta": "*"
  }
}
```

Versions shown are examples — the Expo SDK dictates them (`npx expo install --fix`).

**Critical rules:**
- `react` and `react-dom` **same exact version without `^`** — different versions cause fatal crash
- `zustand`: use **v4** (`^4.5.5`) — v5 has `import.meta` in `.mjs` files that breaks Hermes
- `date-fns`: use **v3** (`^3.6.0`) — v4 is ESM-only with `import.meta`

### 3. `babel.config.js` — required

```javascript
module.exports = function (api) {
  api.cache(true);
  return {
    presets: [
      [
        'babel-preset-expo',
        {
          unstable_transformImportMeta: true,
        },
      ],
    ],
  };
};
```

**DO NOT use `unstable_conditionNames` in metro.config** — this breaks resolution of `"main": "expo-router/entry"` and Metro falls back to `expo/AppEntry.js`, causing a white screen.

### 4. `metro.config.js` — required

```javascript
const { getDefaultConfig } = require('expo/metro-config');
const path = require('path');

const projectRoot = __dirname;
const workspaceRoot = path.resolve(projectRoot, '../..');

const config = getDefaultConfig(projectRoot);

config.watchFolders = [workspaceRoot];

config.resolver.nodeModulesPaths = [
  path.resolve(projectRoot, 'node_modules'),
  path.resolve(workspaceRoot, 'node_modules'),
];

// Resolve local workspace packages directly from src/
// Replace @your-app/* with your actual package scope
config.resolver.extraNodeModules = {
  '@your-app/shared-types': path.resolve(workspaceRoot, 'packages/shared-types/src'),
  '@your-app/utils': path.resolve(workspaceRoot, 'packages/utils/src'),
};

// Pin React sub-paths — Metro can't resolve react/jsx-dev-runtime from inside the pnpm virtual store
const reactPath = path.resolve(projectRoot, 'node_modules', 'react');
config.resolver.resolveRequest = (context, moduleName, platform) => {
  const PINNED = {
    'react':                 path.join(reactPath, 'index.js'),
    'react/jsx-runtime':     path.join(reactPath, 'jsx-runtime.js'),
    'react/jsx-dev-runtime': path.join(reactPath, 'jsx-dev-runtime.js'),
  };
  if (PINNED[moduleName]) return { filePath: PINNED[moduleName], type: 'sourceFile' };
  return context.resolveRequest(context, moduleName, platform);
};

// Allows require.context so Expo Router can discover routes automatically
config.transformer.unstable_allowRequireContext = true;

// Force Babel to transform zustand (uses import.meta in .mjs even in v4)
config.transformer.transformIgnorePatterns = [
  'node_modules/(?!(zustand|@your-app)/)',
];

module.exports = config;
```

### 5. `app.json` — include `web` in platforms

```json
{
  "expo": {
    "platforms": ["ios", "android", "web"],
    "web": { "bundler": "metro", "output": "single" },
    "plugins": ["expo-router"],
    "experiments": { "typedRoutes": true }
  }
}
```

### 6. Required explicit dependencies

pnpm does not hoist transitive dependencies automatically. Declare in `package.json`:

```json
{
  "dependencies": {
    "@babel/runtime": "*",
    "expo-constants": "<SDK-matched version>",
    "expo-linking": "<SDK-matched version>",
    "react-native-safe-area-context": "*",
    "react-native-screens": "*",
    "@react-native-async-storage/async-storage": "*"
  }
}
```

**Rule:** any package with native iOS/Android code that is a transitive dep of `expo-router` MUST be explicitly declared in `package.json` for CocoaPods to include it. Let `npx expo install <pkg>` pick the SDK-matched version.

### 7. `.pnpm` URL issue in Expo Web — proxy required

> **pnpm version matters:** pnpm < v11 generates relative paths → rewriting proxy needed. pnpm v11+ generates absolute paths → transparent proxy.

**Solution (pnpm < v11):** create `apps/mobile/web-proxy.js`:

```javascript
const http = require('http');
const METRO_PORT = parseInt(process.argv[2] || '8082', 10);
const PROXY_PORT = parseInt(process.argv[3] || '8081', 10);
const PNPM_RE = /src="(\/(?:\.\.\/)*node_modules\/\.pnpm\/[^"]*expo-router[^"]*\/node_modules\/expo-router\/entry\.bundle[^"]*)"/g;

http.createServer((req, res) => {
  const opts = { hostname: 'localhost', port: METRO_PORT, path: req.url, method: req.method,
                 headers: { ...req.headers, host: `localhost:${METRO_PORT}` } };
  http.request(opts, (pr) => {
    const isHtml = (pr.headers['content-type'] || '').includes('text/html');
    if (isHtml) {
      const chunks = [];
      pr.on('data', c => chunks.push(c));
      pr.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        const fixed = body.replace(PNPM_RE, (_, url) => {
          const qs = url.indexOf('?') >= 0 ? url.slice(url.indexOf('?')) : '';
          return `src="/node_modules/expo-router/entry.bundle${qs}"`;
        });
        const buf = Buffer.from(fixed, 'utf8');
        const hdrs = { ...pr.headers, 'content-length': buf.length };
        delete hdrs['transfer-encoding'];
        res.writeHead(pr.statusCode, hdrs);
        res.end(buf);
      });
    } else {
      res.writeHead(pr.statusCode, pr.headers);
      pr.pipe(res);
    }
  }).on('error', e => { res.writeHead(502); res.end(e.message); })
    .end(req.read());
}).listen(PROXY_PORT, () => console.log(`Proxy: http://localhost:${PROXY_PORT} → Metro: ${METRO_PORT}`));
```

**pnpm v11+ — transparent proxy:**

```javascript
const http = require('http');
const METRO_PORT = parseInt(process.argv[2] || '8082', 10);
const PROXY_PORT = parseInt(process.argv[3] || '8081', 10);
http.createServer((req, res) => {
  http.request(
    { hostname: 'localhost', port: METRO_PORT, path: req.url, method: req.method,
      headers: { ...req.headers, host: `localhost:${METRO_PORT}` } },
    (pr) => { res.writeHead(pr.statusCode, pr.headers); pr.pipe(res); }
  ).on('error', e => { res.writeHead(502); res.end(e.message); }).end(req.read());
}).listen(PROXY_PORT, () => console.log(`Proxy: http://localhost:${PROXY_PORT} → Metro: ${METRO_PORT}`));
```

**Scripts in `package.json`:**
```json
{ "scripts": { "web": "expo start --web --port 8082 --clear", "web:proxy": "node web-proxy.js 8082 8081" } }
```

```bash
# Terminal 1: cd apps/mobile && pnpm web
# Terminal 2: cd apps/mobile && pnpm web:proxy
# Access: http://localhost:8081 (not 8082)
```

---

## Mobile app setup order

```bash
# 1. Create files (package.json, app.json, tsconfig, babel.config.js, metro.config.js)
pnpm install
cd apps/mobile && npx expo install --fix
cd apps/mobile && npx expo start --web --port 8081 --clear
# --clear is REQUIRED after any change to babel.config.js or metro.config.js
```

**Critical:** if `expo start` shows "Starting project at /...monorepo-root", Metro loads the wrong project — always confirm the CWD.

---

## pnpm 11 — `allowBuilds` must include `@swc/core`

If the project uses `@swc/core` (NestJS test runner or transpiler), add to `pnpm-workspace.yaml`:

```yaml
allowBuilds:
  '@swc/core': true
```

Without this, pnpm 11 blocks the postinstall script and `@swc/core` fails to compile its native bindings.

---

## React Navigation — use version 7, not 6

`@react-navigation/core@^6` and `@react-navigation/native@^6` cause `ERR_PNPM_NO_MATCHING_VERSION` — v6 no longer exists on npm. Expo SDK 52+ (`expo-router` v4 and later) depends on React Navigation v7.

```json
{
  "dependencies": {
    "@react-navigation/core": "^7.0.0",
    "@react-navigation/native": "^7.0.0"
  }
}
```
