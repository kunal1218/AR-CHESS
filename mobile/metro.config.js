const path = require('path');
const { getDefaultConfig } = require('expo/metro-config');

const projectRoot = __dirname;
const workspaceRoot = path.resolve(projectRoot, '..');
const arClientRoot = path.resolve(workspaceRoot, 'ar-client');

const config = getDefaultConfig(projectRoot);

config.watchFolders = [arClientRoot];
config.resolver.unstable_enableSymlinks = true;
config.resolver.nodeModulesPaths = [path.resolve(projectRoot, 'node_modules')];

module.exports = config;
