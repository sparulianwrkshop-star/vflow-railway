#!/usr/bin/env node

const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');

const BASE_URL = process.env.VFLOW_BASE_URL || 'workflow-db.kelompok3.vflow.parulian.my.id';
const DEFAULT_TENANT = process.env.VFLOW_TENANT || '_default';
const REQUEST_TIMEOUT_MS = parseInt(process.env.VFLOW_REQ_TIMEOUT_MS || '12000', 10);

const [rawCmd, rawSubCmd, ...restArgs] = process.argv.slice(2);

function usage() {
  console.log(`Usage:
  scripts/vflow-admin.sh | .ps1 | .bat status
  scripts/vflow-admin.sh | .ps1 | .bat workflows list [tenant]
  scripts/vflow-admin.sh | .ps1 | .bat workflows provision <path-to-workflow.yaml>
  scripts/vflow-admin.sh | .ps1 | .bat workflows unprovision <workflow-id>
  scripts/vflow-admin.sh | .ps1 | .bat rules list
  scripts/vflow-admin.sh | .ps1 | .bat rules remove <rule_set_id>

Environment:
  VFLOW_BASE_URL  (default: workflow-db.kelompok3.vflow.parulian.my.id)
  VFLOW_TENANT    (default: _default)
`);
}

function get(urlPath) {
  return request(urlPath, { method: 'GET' });
}

function postYaml(urlPath, filePath, tenant = DEFAULT_TENANT) {
  const body = fs.readFileSync(filePath, 'utf8');
  return request(urlPath, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/yaml',
      'X-Tenant-Id': tenant,
    },
    body,
  });
}

function del(urlPath, payload) {
  return request(urlPath, {
    method: 'DELETE',
    headers: payload
      ? { 'Content-Type': 'application/json' }
      : undefined,
    body: payload,
  });
}

function request(path, { method = 'GET', headers = {}, body } = {}) {
  if (!path) {
    throw new Error('path is required');
  }

  const normalizedBase = BASE_URL.endsWith('/') ? BASE_URL : `${BASE_URL}/`;
  const url = new URL(path.replace(/^\//, ''), normalizedBase);

  const client = url.protocol === 'https:' ? https : http;
  const options = {
    method,
    hostname: url.hostname,
    port: url.port || (url.protocol === 'https:' ? 443 : 80),
    path: `${url.pathname}${url.search}`,
    headers,
  };

  const resolvedBody = body === undefined ? null : (typeof body === 'string' ? body : JSON.stringify(body));
  if (resolvedBody !== null) {
    options.headers['Content-Length'] = Buffer.byteLength(resolvedBody);
  }

  return new Promise((resolve, reject) => {
  const req = client.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
    res.on('end', () => {
        const isJSON = (res.headers['content-type'] || '').includes('application/json');
        const text = data || '';

        if (res.statusCode >= 400) {
          const bodyPreview = text.length > 3000 ? `${text.slice(0, 3000)}...` : text;
          reject(new Error(`${method} ${url.href} -> HTTP ${res.statusCode}\n${bodyPreview}`));
          return;
        }

        if (isJSON) {
          try {
            resolve(JSON.stringify(JSON.parse(text), null, 2));
          } catch {
            resolve(text);
          }
        } else {
          resolve(text);
        }
    });
  });

  req.on('error', reject);
  req.setTimeout(REQUEST_TIMEOUT_MS, () => {
    req.destroy(new Error(`request timeout after ${REQUEST_TIMEOUT_MS}ms to ${url.href}`));
  });
  req.end(resolvedBody);
  });
}

async function main() {
  if (!rawCmd || rawCmd === '--help' || rawCmd === '-h' || rawCmd === 'help') {
    usage();
    return;
  }

  if (rawCmd === 'status') {
    console.log('# server health');
    console.log(await get('/health'));
    console.log('# server overview');
    console.log(await get('/_vflow/api/overview'));
    return;
  }

  if (rawCmd === 'workflows') {
    const tenant = restArgs[0] || DEFAULT_TENANT;

    if (rawSubCmd === 'list') {
      console.log(`# workflows (tenant=${tenant})`);
      console.log(await get(`/_vflow/api/workflows?tenant=${encodeURIComponent(tenant)}`));
      return;
    }

    if (rawSubCmd === 'provision') {
      const filePath = restArgs[0];
      if (!filePath) {
        usage();
        throw new Error('provision requires <path-to-workflow.yaml>');
      }
      console.log(`# provision workflow from ${filePath}`);
      console.log(await postYaml('/api/admin/workflow/upload', filePath));
      return;
    }

    if (rawSubCmd === 'unprovision') {
      const workflowId = restArgs[0];
      if (!workflowId) {
        usage();
        throw new Error('unprovision requires <workflow-id>');
      }
      console.log(`# unprovision workflow: ${workflowId}`);
      console.log(await del(`/_vflow/api/workflows/${encodeURIComponent(workflowId)}?tenant=${encodeURIComponent(DEFAULT_TENANT)}`));
      return;
    }

    usage();
    throw new Error(`unknown workflows subcommand: ${rawSubCmd}`);
  }

  if (rawCmd === 'rules') {
    if (rawSubCmd === 'list') {
      console.log('# vrules');
      console.log(await get('/api/admin/vrules'));
      return;
    }

    if (rawSubCmd === 'remove') {
      const ruleSetId = restArgs[0];
      if (!ruleSetId) {
        usage();
        throw new Error('remove requires <rule_set_id>');
      }
      console.log(`# remove vrule: ${ruleSetId}`);
      console.log(await del('/api/admin/vrule', { rule_set_id: ruleSetId }));
      return;
    }

    usage();
    throw new Error(`unknown rules subcommand: ${rawSubCmd}`);
  }

  usage();
  throw new Error(`unknown command: ${rawCmd}`);
}

main().catch((error) => {
  console.error(`Error: ${error.message}`);
  process.exit(1);
});
