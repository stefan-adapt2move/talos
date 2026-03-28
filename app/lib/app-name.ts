/**
 * Configurable application name.
 * Set APP_NAME env var to customize (default: "Atlas").
 * All derived names (DB, config dirs, env prefix) follow automatically.
 */
const APP_NAME = process.env.APP_NAME || "Atlas";
const APP_NAME_LOWER = APP_NAME.toLowerCase();
const APP_NAME_UPPER = APP_NAME.toUpperCase();

export const appName = APP_NAME;
export const appNameLower = APP_NAME_LOWER;
export const dbFilename = `${APP_NAME_LOWER}.db`;
export const mpcConfigDir = `.${APP_NAME_LOWER}-mcp`;
export const injectDir = `.${APP_NAME_LOWER}-inject`;
export const runtimeConfigFile = `.${APP_NAME_LOWER}-runtime-config.json`;
export const envPrefix = APP_NAME_UPPER;
export const pausedMarker = `.${APP_NAME_LOWER}-paused`;
