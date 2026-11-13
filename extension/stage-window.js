'use strict';
const stageToken = new URLSearchParams(location.search).get('stageToken');
if (stageToken && /^[a-zA-Z0-9_-]+$/.test(stageToken)) document.title = `amcu-stage-${stageToken}`;
