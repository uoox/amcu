// amcu bridge — content script.
//
// Runs in every frame of a tab the CLI asks about, in the extension's isolated
// world. It does the reading: an accessibility-flavoured snapshot of the DOM
// with stable element refs, plus the measurements the background worker needs
// to deliver a real input event through the debugger protocol. It never
// dispatches trusted input itself; that is the worker's job.
//
// State lives on globalThis so repeated injections are idempotent and refs
// survive between commands for the lifetime of the document.

(() => {
  if (globalThis.__amcu) return;

  const VERSION = 1;

  // ---------------------------------------------------------------------------
  // Errors carry the same shape the CLI prints: a code, a message, next steps.

  class BridgeError extends Error {
    constructor(code, message, nextSteps = []) {
      super(message);
      this.code = code;
      this.nextSteps = nextSteps;
    }
    toJSON() {
      return { code: this.code, message: this.message, nextSteps: this.nextSteps };
    }
  }

  // ---------------------------------------------------------------------------
  // Roles

  const KNOWN_ROLES = new Set([
    'alert', 'alertdialog', 'application', 'article', 'banner', 'blockquote', 'button', 'caption', 'cell',
    'checkbox', 'code', 'columnheader', 'combobox', 'complementary', 'contentinfo', 'definition', 'deletion',
    'dialog', 'directory', 'document', 'emphasis', 'feed', 'figure', 'form', 'generic', 'grid', 'gridcell',
    'group', 'heading', 'img', 'insertion', 'link', 'list', 'listbox', 'listitem', 'log', 'main', 'mark',
    'marquee', 'math', 'menu', 'menubar', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'meter',
    'navigation', 'none', 'note', 'option', 'paragraph', 'presentation', 'progressbar', 'radio', 'radiogroup',
    'region', 'row', 'rowgroup', 'rowheader', 'scrollbar', 'search', 'searchbox', 'separator', 'slider',
    'spinbutton', 'status', 'strong', 'subscript', 'superscript', 'switch', 'tab', 'table', 'tablist',
    'tabpanel', 'term', 'textbox', 'time', 'timer', 'toolbar', 'tooltip', 'tree', 'treegrid', 'treeitem',
    'iframe', 'video', 'audio'
  ]);

  const INTERACTIVE_ROLES = new Set([
    'button', 'link', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox', 'listbox', 'option',
    'menuitem', 'menuitemcheckbox', 'menuitemradio', 'tab', 'slider', 'spinbutton', 'switch', 'treeitem',
    'scrollbar', 'gridcell'
  ]);

  // Roles whose accessible name may be computed from their content (accname 2F).
  const NAME_FROM_CONTENT = new Set([
    'button', 'cell', 'checkbox', 'columnheader', 'gridcell', 'heading', 'link', 'menuitem',
    'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'rowheader', 'switch', 'tab',
    'tooltip', 'treeitem'
  ]);

  const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'META', 'LINK', 'TITLE', 'BASE']);

  const SECRET_MARKERS = [
    'secure', 'password', 'passwd', 'passcode', 'pin code', 'verification code', 'one-time code',
    'otp', 'secret', 'token', 'cvv', 'cvc'
  ];

  function tagOf(el) {
    return el.tagName ? el.tagName.toLowerCase() : '';
  }

  function attr(el, name) {
    const value = el.getAttribute && el.getAttribute(name);
    return value === null || value === undefined ? null : value;
  }

  function hasName(el) {
    return !!(attr(el, 'aria-label') || attr(el, 'aria-labelledby') || attr(el, 'title'));
  }

  function implicitRole(el) {
    const tag = tagOf(el);
    switch (tag) {
      case 'a':
      case 'area':
        return el.hasAttribute('href') ? 'link' : null;
      case 'button':
        return 'button';
      case 'input': {
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        if (type === 'hidden') return null;
        if (['button', 'submit', 'reset', 'image', 'file'].includes(type)) return 'button';
        if (type === 'checkbox') return 'checkbox';
        if (type === 'radio') return 'radio';
        if (type === 'range') return 'slider';
        if (type === 'number') return 'spinbutton';
        if (type === 'search') return el.hasAttribute('list') ? 'combobox' : 'searchbox';
        if (['email', 'tel', 'text', 'url'].includes(type)) return el.hasAttribute('list') ? 'combobox' : 'textbox';
        return 'textbox';
      }
      case 'select':
        return (el.multiple || el.size > 1) ? 'listbox' : 'combobox';
      case 'textarea':
        return 'textbox';
      case 'option':
        return 'option';
      case 'optgroup':
        return 'group';
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6':
        return 'heading';
      case 'img':
        return attr(el, 'alt') === '' ? 'presentation' : 'img';
      case 'svg':
        return 'img';
      case 'ul': case 'ol': case 'menu':
        return 'list';
      case 'li':
        return 'listitem';
      case 'nav':
        return 'navigation';
      case 'main':
        return 'main';
      case 'header':
        return el.closest('article, aside, main, nav, section') ? null : 'banner';
      case 'footer':
        return el.closest('article, aside, main, nav, section') ? null : 'contentinfo';
      case 'aside':
        return 'complementary';
      case 'article':
        return 'article';
      case 'section':
        return hasName(el) ? 'region' : null;
      case 'form':
        return hasName(el) ? 'form' : null;
      case 'search':
        return 'search';
      case 'table':
        return 'table';
      case 'thead': case 'tbody': case 'tfoot':
        return 'rowgroup';
      case 'tr':
        return 'row';
      case 'td':
        return 'cell';
      case 'th':
        return el.getAttribute('scope') === 'row' ? 'rowheader' : 'columnheader';
      case 'caption':
        return 'caption';
      case 'dialog':
        return 'dialog';
      case 'details':
        return 'group';
      case 'summary':
        return 'button';
      case 'fieldset':
        return 'group';
      case 'p':
        return 'paragraph';
      case 'hr':
        return 'separator';
      case 'blockquote':
        return 'blockquote';
      case 'code':
        return 'code';
      case 'em':
        return 'emphasis';
      case 'strong':
        return 'strong';
      case 'sup':
        return 'superscript';
      case 'sub':
        return 'subscript';
      case 'time':
        return 'time';
      case 'mark':
        return 'mark';
      case 'del':
        return 'deletion';
      case 'ins':
        return 'insertion';
      case 'dt': case 'dfn':
        return 'term';
      case 'dd':
        return 'definition';
      case 'progress':
        return 'progressbar';
      case 'meter':
        return 'meter';
      case 'output':
        return 'status';
      case 'iframe': case 'frame':
        return 'iframe';
      case 'video':
        return 'video';
      case 'audio':
        return 'audio';
      case 'figure':
        return 'figure';
      case 'math':
        return 'math';
      case 'html': case 'body':
        return null;
      default:
        return null;
    }
  }

  function explicitRole(el) {
    const raw = attr(el, 'role');
    if (!raw) return null;
    for (const token of raw.trim().split(/\s+/)) {
      const role = token.toLowerCase();
      if (KNOWN_ROLES.has(role)) return role;
    }
    return null;
  }

  function isEditableHost(el) {
    if (!el.isContentEditable) return false;
    const parent = el.parentElement;
    return !(parent && parent.isContentEditable);
  }

  /// The role a snapshot line reports. `null` means "generic": no line of its
  /// own, children promoted to the parent.
  function roleOf(el) {
    let role = explicitRole(el);
    if (role === 'presentation' || role === 'none') {
      // A focusable element cannot renounce its role (ARIA conflict rule).
      return isFocusable(el) ? (implicitRole(el) || 'generic') : null;
    }
    if (!role) role = implicitRole(el);
    if (role === 'presentation') return null;
    if (!role && isEditableHost(el)) return 'textbox';
    return role;
  }

  function isDisabled(el) {
    if (el.disabled === true) return true;
    if (attr(el, 'aria-disabled') === 'true') return true;
    const fieldset = el.closest && el.closest('fieldset[disabled]');
    if (fieldset && !(el.closest('legend') && fieldset.querySelector('legend') === el.closest('legend'))) return true;
    return false;
  }

  function isFocusable(el) {
    if (isDisabled(el)) return false;
    const tag = tagOf(el);
    if (el.hasAttribute('tabindex')) return el.tabIndex >= 0;
    if (['input', 'select', 'textarea', 'button'].includes(tag)) return tag !== 'input' || el.type !== 'hidden';
    if ((tag === 'a' || tag === 'area') && el.hasAttribute('href')) return true;
    if (tag === 'iframe' || tag === 'summary') return true;
    if (isEditableHost(el)) return true;
    return false;
  }

  // ---------------------------------------------------------------------------
  // Visibility

  function isStyleHidden(style) {
    return style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse';
  }

  function hasBox(el) {
    const rects = el.getClientRects();
    for (const rect of rects) {
      if (rect.width > 0 && rect.height > 0) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Accessible names (a pragmatic subset of accname 1.2)

  function normalize(text) {
    return (text || '').replace(/\s+/g, ' ').trim();
  }

  function isBlockLike(el) {
    const tag = tagOf(el);
    if (['div', 'p', 'li', 'tr', 'td', 'th', 'section', 'article', 'header', 'footer', 'nav', 'main', 'aside',
      'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'dl', 'dt', 'dd', 'table', 'br', 'blockquote', 'pre',
      'fieldset', 'legend', 'form', 'figure', 'figcaption', 'address', 'hr'].includes(tag)) return true;
    try {
      const display = getComputedStyle(el).display;
      return !display.startsWith('inline') && display !== 'contents';
    } catch (_) {
      return false;
    }
  }

  function svgTitle(el) {
    for (const child of el.children) {
      if (tagOf(child) === 'title') return normalize(child.textContent);
    }
    return '';
  }

  function textAlternative(node, ctx) {
    if (node.nodeType === Node.TEXT_NODE) return node.data || '';
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    const el = node;
    if (SKIP_TAGS.has(el.tagName)) return '';
    if (ctx.visited.has(el)) return '';
    ctx.visited.add(el);
    try {
      if (!ctx.includeHidden) {
        if (attr(el, 'aria-hidden') === 'true') return '';
        const style = getComputedStyle(el);
        if (isStyleHidden(style)) return '';
      }
      const tag = tagOf(el);
      if (tag === 'br') return ' ';
      const ariaLabel = normalize(attr(el, 'aria-label'));
      if (ariaLabel) return ' ' + ariaLabel + ' ';
      const labelledBy = attr(el, 'aria-labelledby');
      if (labelledBy && !ctx.inLabelledBy) {
        const viaRefs = nameFromLabelledBy(el, labelledBy, ctx);
        if (viaRefs) return ' ' + viaRefs + ' ';
      }
      const role = roleOf(el);
      // Embedded controls contribute their value (accname 2E).
      if (role === 'textbox' || role === 'searchbox') {
        return ' ' + (el.value !== undefined ? el.value : el.textContent) + ' ';
      }
      if (role === 'combobox' || role === 'listbox') {
        if (tag === 'select') {
          const selected = Array.from(el.selectedOptions || []).map(o => o.label || o.textContent).join(' ');
          return ' ' + selected + ' ';
        }
        return ' ' + (el.value || '') + ' ';
      }
      if (role === 'slider' || role === 'spinbutton' || role === 'progressbar' || role === 'meter') {
        return ' ' + (attr(el, 'aria-valuetext') || attr(el, 'aria-valuenow') || el.value || '') + ' ';
      }
      if (tag === 'img' || tag === 'area') return ' ' + (attr(el, 'alt') || attr(el, 'title') || '') + ' ';
      if (tag === 'svg') return ' ' + svgTitle(el) + ' ';
      if (tag === 'input') {
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        if (['button', 'submit', 'reset'].includes(type)) return ' ' + (el.value || '') + ' ';
        if (type === 'image') return ' ' + (attr(el, 'alt') || el.value || '') + ' ';
      }
      let text = '';
      for (const child of childNodesOf(el)) text += textAlternative(child, ctx);
      // CSS generated content is part of what the user sees.
      text = pseudoContent(el, '::before') + text + pseudoContent(el, '::after');
      if (!text.trim()) {
        const title = normalize(attr(el, 'title'));
        if (title) text = title;
      }
      return isBlockLike(el) ? ' ' + text + ' ' : text;
    } finally {
      ctx.visited.delete(el);
    }
  }

  function pseudoContent(el, pseudo) {
    try {
      const content = getComputedStyle(el, pseudo).content;
      if (!content || content === 'none' || content === 'normal') return '';
      const match = /^"(.*)"$/.exec(content) || /^'(.*)'$/.exec(content);
      return match ? match[1] : '';
    } catch (_) {
      return '';
    }
  }

  function nameFromLabelledBy(el, ids, ctx) {
    const parts = [];
    for (const id of ids.trim().split(/\s+/)) {
      const target = el.getRootNode().getElementById ? el.getRootNode().getElementById(id) : document.getElementById(id);
      if (!target) continue;
      const inner = { visited: new Set(ctx.visited), includeHidden: true, inLabelledBy: true };
      parts.push(normalize(textAlternative(target, inner)));
    }
    return normalize(parts.join(' '));
  }

  function nativeLabel(el) {
    const tag = tagOf(el);
    if (el.labels && el.labels.length) {
      const parts = [];
      for (const label of el.labels) {
        const ctx = { visited: new Set([el]), includeHidden: false, inLabelledBy: false };
        parts.push(normalize(textAlternative(label, ctx)));
      }
      const joined = normalize(parts.join(' '));
      if (joined) return joined;
    }
    if (tag === 'input') {
      const type = (el.getAttribute('type') || 'text').toLowerCase();
      if (['button', 'submit', 'reset'].includes(type)) {
        if (el.value) return el.value;
        return type === 'submit' ? 'Submit' : type === 'reset' ? 'Reset' : '';
      }
      if (type === 'image') return attr(el, 'alt') || el.value || 'Submit';
      if (type === 'file') return 'Choose file';
    }
    if (tag === 'img' || tag === 'area') return normalize(attr(el, 'alt'));
    if (tag === 'svg') return svgTitle(el);
    if (tag === 'table') {
      const caption = el.querySelector(':scope > caption');
      if (caption) return normalize(caption.textContent);
    }
    if (tag === 'fieldset') {
      const legend = el.querySelector(':scope > legend');
      if (legend) return normalize(legend.textContent);
    }
    if (tag === 'figure') {
      const cap = el.querySelector(':scope > figcaption');
      if (cap) return normalize(cap.textContent);
    }
    if (tag === 'iframe' || tag === 'frame') return normalize(attr(el, 'title'));
    if (tag === 'summary' || tag === 'option' || tag === 'optgroup') return normalize(el.label !== undefined && tag === 'optgroup' ? el.label : el.textContent);
    return '';
  }

  function accessibleName(el, role) {
    const labelledBy = attr(el, 'aria-labelledby');
    if (labelledBy) {
      const name = nameFromLabelledBy(el, labelledBy, { visited: new Set(), includeHidden: true, inLabelledBy: true });
      if (name) return name;
    }
    const ariaLabel = normalize(attr(el, 'aria-label'));
    if (ariaLabel) return ariaLabel;
    const native = nativeLabel(el);
    if (native) return native;
    if (role && NAME_FROM_CONTENT.has(role)) {
      const ctx = { visited: new Set(), includeHidden: false, inLabelledBy: false };
      const content = normalize(textAlternative(el, ctx));
      if (content) return content;
    }
    const title = normalize(attr(el, 'title'));
    if (title) return title;
    const placeholder = normalize(attr(el, 'placeholder') || attr(el, 'aria-placeholder'));
    if (placeholder) return placeholder;
    return '';
  }

  // ---------------------------------------------------------------------------
  // Values and states

  function holdsSecret(el, name) {
    const type = (attr(el, 'type') || '').toLowerCase();
    if (type === 'password') return true;
    const autocomplete = (attr(el, 'autocomplete') || '').toLowerCase();
    if (autocomplete.includes('password') || autocomplete === 'one-time-code' || autocomplete.includes('cc-csc')) return true;
    const haystack = [name, attr(el, 'name'), attr(el, 'id'), attr(el, 'placeholder'), attr(el, 'aria-label')]
      .filter(Boolean).join(' ').toLowerCase();
    return SECRET_MARKERS.some(marker => haystack.includes(marker));
  }

  function checkedState(el, role) {
    if (tagOf(el) === 'input' && (el.type === 'checkbox' || el.type === 'radio')) {
      if (el.indeterminate) return 'mixed';
      return el.checked ? 'true' : 'false';
    }
    const aria = attr(el, 'aria-checked');
    if (aria === 'true' || aria === 'false' || aria === 'mixed') return aria;
    if (role === 'switch' || role === 'checkbox' || role === 'radio' || role === 'menuitemcheckbox' || role === 'menuitemradio') return 'false';
    return null;
  }

  function headingLevel(el) {
    const aria = parseInt(attr(el, 'aria-level'), 10);
    if (aria >= 1) return aria;
    const match = /^h([1-6])$/.exec(tagOf(el));
    return match ? parseInt(match[1], 10) : null;
  }

  // ---------------------------------------------------------------------------
  // Tree walking (light DOM, open shadow roots, slots)

  function childNodesOf(el) {
    if (el.shadowRoot) return Array.from(el.shadowRoot.childNodes);
    if (tagOf(el) === 'slot') return el.assignedNodes({ flatten: true });
    return Array.from(el.childNodes);
  }

  // ---------------------------------------------------------------------------
  // Refs

  const state = {
    generation: 0,
    counter: 0,
    byRef: new Map(),        // ref -> { el, role, name, generation }
    byElement: new WeakMap(), // el -> ref
    lastSnapshotAt: 0
  };

  function refFor(el, role, name) {
    const existing = state.byElement.get(el);
    if (existing) {
      const record = state.byRef.get(existing);
      if (record && record.el === el) {
        record.role = role;
        record.name = name;
        record.generation = state.generation;
        return existing;
      }
    }
    state.counter += 1;
    const ref = 'e' + state.counter;
    state.byRef.set(ref, { el, role, name, generation: state.generation });
    state.byElement.set(el, ref);
    return ref;
  }

  function describe(role, name) {
    return name ? `${role} "${name}"` : role;
  }

  function resolveRef(ref) {
    const record = state.byRef.get(ref);
    if (!record) {
      throw new BridgeError('element_not_found', `ref ${ref} is not known in this frame`, [
        'Refs come from `amcu browser snapshot`; take one (or a fresh one) and use the refs it prints.',
        'A ref like f123e4 belongs to frame f123 — the frame id is part of the ref, do not drop it.'
      ]);
    }
    const el = record.el;
    if (!el.isConnected) {
      throw new BridgeError('stale_snapshot', `element ${ref} (${describe(record.role, record.name)}) was removed from the page`, [
        'Re-run `amcu browser snapshot`; the page changed after it was captured.'
      ]);
    }
    const role = roleOf(el) || 'generic';
    const name = accessibleName(el, role);
    if (role !== record.role || name !== record.name) {
      throw new BridgeError('stale_snapshot', `element ${ref} changed: was ${describe(record.role, record.name)}, now ${describe(role, name)}`, [
        'Re-run `amcu browser snapshot` and use the new refs; the interface changed after it was captured.'
      ]);
    }
    return { el, record, fromEarlierSnapshot: record.generation !== state.generation };
  }

  // ---------------------------------------------------------------------------
  // Snapshot

  const TEXT_CAP = 300;

  function cap(text) {
    if (text.length <= TEXT_CAP) return text;
    return text.slice(0, TEXT_CAP) + `…[+${text.length - TEXT_CAP} chars]`;
  }

  function quote(text) {
    return '"' + text.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"';
  }

  function snapshot(options) {
    // Only a whole-document snapshot starts a new generation; a scoped one
    // must not make every other ref look old.
    if (!options.selector) state.generation += 1;
    state.lastSnapshotAt = Date.now();
    const maxNodes = Math.max(1, options.maxNodes || 1500);
    const allRefs = !!options.allRefs;
    const interactiveOnly = !!options.interactiveOnly;

    let root = document.body || document.documentElement;
    if (options.selector) {
      let found;
      try {
        found = document.querySelector(options.selector);
      } catch (error) {
        throw new BridgeError('invalid_argument', `--selector is not a valid CSS selector: ${error.message}`);
      }
      if (!found) {
        throw new BridgeError('element_not_found', `no element matches --selector '${options.selector}' in this frame`, [
          'Check the selector against `amcu browser snapshot` output, or drop --selector to see the whole page.'
        ]);
      }
      root = found;
    }
    if (!root) {
      return { text: '', nodes: 0, rendered: 0, truncated: false, hiddenGenerics: 0, url: location.href, title: document.title, iframes: [] };
    }

    const stats = { nodes: 0, hiddenGenerics: 0 };
    const active = document.activeElement;
    const iframes = [];

    // Build an intermediate tree first, then render within the budget.
    function build(el, parentCursorPointer, depth) {
      if (SKIP_TAGS.has(el.tagName)) return [];
      if (attr(el, 'aria-hidden') === 'true') return [];
      let style;
      try {
        style = getComputedStyle(el);
      } catch (_) {
        return [];
      }
      if (isStyleHidden(style)) return [];
      // Covers content-visibility (closed <details>, skipped subtrees) too.
      if (el.checkVisibility && !el.checkVisibility({ contentVisibilityAuto: true, visibilityProperty: true })) return [];
      const tag = tagOf(el);
      const cursorPointer = style.cursor === 'pointer';
      const pointerHere = cursorPointer && !parentCursorPointer;
      const role = roleOf(el);
      const boxed = tag === 'slot' || style.display === 'contents' || hasBox(el);

      const children = [];
      const collectChildren = () => {
        for (const child of childNodesOf(el)) {
          if (child.nodeType === Node.TEXT_NODE) {
            const text = normalize(child.data);
            if (text) children.push({ text });
          } else if (child.nodeType === Node.ELEMENT_NODE) {
            for (const built of build(child, cursorPointer, depth + 1)) children.push(built);
          }
        }
      };

      const focusable = isFocusable(el);
      const interactive = (role && INTERACTIVE_ROLES.has(role)) || focusable || pointerHere || el.hasAttribute('onclick') || isEditableHost(el);

      // Generic containers get no line of their own unless they behave like a control.
      if (!role) {
        if (!boxed && !interactive) {
          collectChildren();
          return children;
        }
        if (!interactive) {
          collectChildren();
          if (!options.keepGenerics) {
            stats.hiddenGenerics += 1;
            return children;
          }
        }
      }
      if (!boxed && !interactive && role !== 'option') {
        // No box on screen: an unrendered element (e.g. an empty inline). Its
        // children may still be visible.
        collectChildren();
        return children;
      }

      const effectiveRole = role || 'generic';
      stats.nodes += 1;
      const name = accessibleName(el, effectiveRole);
      const node = { role: effectiveRole, name, el, attrs: [], children: [] };

      if (allRefs || interactive || effectiveRole === 'iframe' || effectiveRole === 'img' || effectiveRole === 'heading' || effectiveRole === 'dialog') {
        node.ref = refFor(el, effectiveRole, name);
      }
      if (pointerHere && !(role && INTERACTIVE_ROLES.has(role))) node.attrs.push('cursor=pointer');
      if (el === active && el !== document.body) node.attrs.push('active');
      const checked = checkedState(el, effectiveRole);
      if (checked === 'true') node.attrs.push('checked');
      else if (checked === 'mixed') node.attrs.push('checked=mixed');
      if (isDisabled(el)) node.attrs.push('disabled');
      if (attr(el, 'aria-expanded') === 'true') node.attrs.push('expanded');
      if (attr(el, 'aria-pressed') === 'true') node.attrs.push('pressed');
      if (attr(el, 'aria-selected') === 'true' || (tag === 'option' && el.selected)) node.attrs.push('selected');
      if (effectiveRole === 'heading') {
        const level = headingLevel(el);
        if (level) node.attrs.push('level=' + level);
      }
      if (attr(el, 'aria-required') === 'true' || el.required === true) node.attrs.push('required');
      if (attr(el, 'aria-invalid') === 'true') node.attrs.push('invalid');
      if (tag === 'input') {
        // Types the role does not already convey, and that change how input works.
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        if (['file', 'date', 'time', 'datetime-local', 'month', 'week', 'color', 'password', 'email', 'tel', 'url'].includes(type)) node.attrs.push('type=' + type);
      }

      if (effectiveRole === 'iframe') {
        node.ref = node.ref || refFor(el, effectiveRole, name);
        iframes.push({ ref: node.ref, src: attr(el, 'src') || '' });
        return [node];
      }

      // Text-like controls report their value inline.
      if (tag === 'input' || tag === 'textarea') {
        const type = tag === 'input' ? (el.getAttribute('type') || 'text').toLowerCase() : 'textarea';
        if (!['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'hidden'].includes(type)) {
          const value = el.value || '';
          if (value) node.children.push({ text: holdsSecret(el, name) ? '[redacted]' : value });
        }
        return [node];
      }
      if (tag === 'select') {
        const opts = Array.from(el.options || []);
        const selected = opts.filter(o => o.selected).map(o => o.label || o.textContent);
        if (selected.length && effectiveRole === 'combobox') node.children.push({ text: normalize(selected.join(', ')) });
        const limit = 30;
        opts.slice(0, limit).forEach(o => {
          stats.nodes += 1;
          const child = { role: 'option', name: normalize(o.label || o.textContent), attrs: [], children: [] };
          if (o.selected) child.attrs.push('selected');
          if (o.disabled) child.attrs.push('disabled');
          node.children.push(child);
        });
        if (opts.length > limit) node.children.push({ text: `… ${opts.length - limit} more options` });
        return [node];
      }
      if (isEditableHost(el) && effectiveRole === 'textbox') {
        const value = normalize(el.textContent);
        if (value) node.children.push({ text: holdsSecret(el, name) ? '[redacted]' : value });
        return [node];
      }
      if (effectiveRole === 'link') {
        const href = el.href || attr(el, 'href');
        if (href) node.url = href;
      }
      if (effectiveRole === 'img' || tag === 'svg' || tag === 'video' || tag === 'audio' || tag === 'canvas') {
        return [node];
      }
      if (effectiveRole === 'slider' || effectiveRole === 'spinbutton' || effectiveRole === 'progressbar' || effectiveRole === 'meter') {
        const value = attr(el, 'aria-valuetext') || attr(el, 'aria-valuenow') || (el.value !== undefined ? String(el.value) : '');
        if (value) node.children.push({ text: value });
        return [node];
      }

      collectChildren();
      // A cell whose content is structured (links, controls) is described by
      // that content; repeating it all as the cell's name only costs tokens.
      if (['cell', 'gridcell', 'columnheader', 'rowheader'].includes(effectiveRole) && !attr(el, 'aria-label') && !attr(el, 'aria-labelledby')
        && children.some(c => c.text === undefined)) {
        node.name = '';
        node.children = children;
        return [node];
      }
      // When the name came from the content, the content is redundant.
      if (name && NAME_FROM_CONTENT.has(effectiveRole)) {
        const onlyText = children.every(c => c.text !== undefined);
        const joined = normalize(children.map(c => c.text).join(' '));
        if (onlyText && (joined === name || !joined)) {
          node.children = [];
          return [node];
        }
        if (onlyText) {
          node.children = [{ text: joined }];
          return [node];
        }
      }
      // Merge runs of text.
      const merged = [];
      for (const child of children) {
        const last = merged[merged.length - 1];
        if (child.text !== undefined && last && last.text !== undefined) last.text = normalize(last.text + ' ' + child.text);
        else merged.push(child.text !== undefined ? { text: child.text } : child);
      }
      node.children = merged;
      return [node];
    }

    let tree = build(root, false, 0);
    if (root === document.body && tree.length === 0 && root !== document.documentElement) {
      // Nothing visible in body; report body's text at least.
      tree = [];
    }
    if (interactiveOnly) tree = pruneToInteractive(tree);

    // Render within the budget.
    const lines = [];
    let rendered = 0;
    let truncated = false;
    let focusedRef = null;
    function render(nodes, indent) {
      for (const node of nodes) {
        if (rendered >= maxNodes) { truncated = true; return; }
        if (node.text !== undefined) {
          lines.push(`${indent}- text: ${cap(node.text)}`);
          rendered += 1;
          continue;
        }
        let line = `${indent}- ${node.role}`;
        if (node.name) line += ' ' + quote(cap(node.name));
        if (node.ref) line += ` [ref=${node.ref}]`;
        for (const a of node.attrs) line += ` [${a}]`;
        if (node.attrs.includes('active') && node.ref) focusedRef = node.ref;
        const kids = node.children;
        const single = kids.length === 1 && kids[0].text !== undefined && !node.url;
        if (single) {
          line += ': ' + cap(kids[0].text);
          lines.push(line);
          rendered += 1;
          continue;
        }
        if (kids.length || node.url) line += ':';
        lines.push(line);
        rendered += 1;
        if (node.url) lines.push(`${indent}  - /url: ${cap(node.url)}`);
        if (kids.length) render(kids, indent + '  ');
        if (truncated) return;
      }
    }
    render(tree, '');

    return {
      text: lines.join('\n'),
      nodes: stats.nodes,
      rendered,
      truncated,
      hiddenGenerics: stats.hiddenGenerics,
      url: location.href,
      title: document.title,
      focusedRef,
      iframes
    };
  }

  function pruneToInteractive(nodes) {
    const out = [];
    for (const node of nodes) {
      if (node.text !== undefined) continue;
      const kids = pruneToInteractive(node.children || []);
      const keep = node.ref && (INTERACTIVE_ROLES.has(node.role) || node.attrs.includes('cursor=pointer') || node.role === 'generic');
      if (keep) {
        // A control keeps its own text (its value or label) but loses structure.
        const own = (node.children || []).filter(c => c.text !== undefined);
        out.push(Object.assign({}, node, { children: own.concat(kids) }));
      } else {
        for (const kid of kids) out.push(kid);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Measurement for the worker's trusted input

  function bestRect(el) {
    const rects = Array.from(el.getClientRects()).filter(r => r.width > 0 && r.height > 0);
    if (rects.length) {
      // Prefer the largest fragment; an inline link that wraps has several.
      rects.sort((a, b) => (b.width * b.height) - (a.width * a.height));
      return rects[0];
    }
    return el.getBoundingClientRect();
  }

  function withinViewport(rect) {
    return rect.left >= 0 && rect.top >= 0 && rect.right <= window.innerWidth && rect.bottom <= window.innerHeight;
  }

  function scrollElementIntoView(el) {
    try {
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    } catch (_) {
      el.scrollIntoView();
    }
  }

  function scrollIntoViewIfNeeded(el) {
    const rect = bestRect(el);
    if (withinViewport(rect)) return;
    scrollElementIntoView(el);
  }

  function describeElement(el) {
    if (!el || el.nodeType !== Node.ELEMENT_NODE) return 'nothing';
    const role = roleOf(el) || 'generic';
    const name = accessibleName(el, role);
    const ref = state.byElement.get(el);
    let text = describe(role, name);
    if (!name) text += ` <${tagOf(el)}${el.id ? '#' + el.id : ''}>`;
    if (ref && state.byRef.get(ref)?.el === el) text += ` [ref=${ref}]`;
    return text;
  }

  function hitTest(el, x, y) {
    let hit = document.elementFromPoint(x, y);
    // Descend through open shadow roots to the innermost target.
    while (hit && hit.shadowRoot) {
      const inner = hit.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === hit) break;
      hit = inner;
    }
    if (!hit) return { status: 'outside' };
    if (hit === el || el.contains(hit)) return { status: 'ok' };
    // Slotted content: the hit may be a light-DOM descendant reached via a slot.
    let node = hit;
    while (node) {
      if (node === el) return { status: 'ok' };
      node = node.assignedSlot || node.parentNode || (node.host);
    }
    if (hit.contains(el)) return { status: 'ancestor', by: describeElement(hit) };
    return { status: 'obscured', by: describeElement(hit) };
  }

  function measure(params) {
    const { el, fromEarlierSnapshot } = resolveRef(params.ref);
    // 'force' centres the element even if it looks in-view locally: the caller
    // found its frame scrolled out of the top viewport.
    if (params.scroll === 'force') scrollElementIntoView(el);
    else if (params.scroll !== false) scrollIntoViewIfNeeded(el);
    const rect = bestRect(el);
    if (!(rect.width > 0 && rect.height > 0)) {
      throw new BridgeError('element_not_found', `element ${params.ref} has no size on screen`, [
        'It may be hidden or collapsed; re-run `amcu browser snapshot` to see the current state.'
      ]);
    }
    const candidates = [
      [rect.left + rect.width / 2, rect.top + rect.height / 2],
      [rect.left + rect.width / 4, rect.top + rect.height / 4],
      [rect.left + rect.width * 3 / 4, rect.top + rect.height / 4],
      [rect.left + rect.width / 4, rect.top + rect.height * 3 / 4],
      [rect.left + rect.width * 3 / 4, rect.top + rect.height * 3 / 4]
    ];
    let chosen = null;
    let firstMiss = null;
    for (const [x, y] of candidates) {
      const hit = hitTest(el, x, y);
      if (hit.status === 'ok' || hit.status === 'ancestor') { chosen = { x, y, hit }; break; }
      if (!firstMiss) firstMiss = { x, y, hit };
    }
    const result = chosen || firstMiss;
    return {
      x: result.x,
      y: result.y,
      hit: result.hit.status,
      obscuredBy: result.hit.by || null,
      rect: { x: rect.left, y: rect.top, width: rect.width, height: rect.height },
      description: describeElement(el),
      fromEarlierSnapshot,
      viewport: { width: window.innerWidth, height: window.innerHeight },
      devicePixelRatio: window.devicePixelRatio
    };
  }

  // ---------------------------------------------------------------------------
  // Focus / value helpers (untrusted where it does not matter)

  function isTextInput(el) {
    const tag = tagOf(el);
    if (tag === 'textarea') return true;
    if (tag === 'input') {
      const type = (el.getAttribute('type') || 'text').toLowerCase();
      return !['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'hidden', 'range', 'color'].includes(type);
    }
    return false;
  }

  function editableTarget(el) {
    if (isTextInput(el)) return { el, kind: 'input' };
    if (el.isContentEditable) return { el, kind: 'contenteditable' };
    const inner = el.querySelector && el.querySelector('input, textarea, [contenteditable=""], [contenteditable="true"]');
    if (inner) return editableTarget(inner);
    return null;
  }

  function focusForInput(params) {
    const { el, fromEarlierSnapshot } = resolveRef(params.ref);
    const target = editableTarget(el);
    if (!target) {
      const role = roleOf(el) || 'generic';
      throw new BridgeError('unsupported', `element ${params.ref} (${describe(role, accessibleName(el, role))}) is not a text field`, [
        'Text goes into textbox/searchbox/combobox elements or contenteditable regions; pick one of those from the snapshot.',
        'For a checkbox, radio, select or button use `amcu browser click` or `amcu browser select-option`.'
      ]);
    }
    if (isDisabled(target.el) || target.el.readOnly) {
      throw new BridgeError('unsupported', `element ${params.ref} is ${target.el.readOnly ? 'read-only' : 'disabled'} and would ignore input`, [
        'A disabled field means a precondition is unmet; change the state it depends on and re-snapshot.'
      ]);
    }
    scrollIntoViewIfNeeded(target.el);
    target.el.focus({ preventScroll: true });
    const active = document.activeElement;
    if (active !== target.el && !(target.el.contains(active))) {
      throw new BridgeError('unsupported', `element ${params.ref} did not take focus`, [
        'The page may have moved focus elsewhere; run `amcu browser snapshot` and check which element is [active].'
      ]);
    }
    const mode = params.mode || 'append';
    if (target.kind === 'input') {
      const el = target.el;
      const length = (el.value || '').length;
      try {
        if (mode === 'replace') el.setSelectionRange(0, length);
        else el.setSelectionRange(length, length);
      } catch (_) {
        // number/email inputs refuse setSelectionRange; select() still works for replace.
        if (mode === 'replace') el.select();
      }
    } else {
      const selection = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(target.el);
      if (mode !== 'replace') range.collapse(false);
      selection.removeAllRanges();
      selection.addRange(range);
    }
    const assignable = target.kind === 'input' && ['date', 'datetime-local', 'month', 'week', 'time', 'color', 'range', 'number'].includes((target.el.getAttribute('type') || '').toLowerCase());
    return { kind: target.kind, assignable, value: readValue(target.el), fromEarlierSnapshot, description: describeElement(el) };
  }

  function readValue(el) {
    if (isTextInput(el)) return el.value;
    if (el.isContentEditable) return el.textContent;
    if (tagOf(el) === 'select') return Array.from(el.selectedOptions).map(o => o.value);
    return el.value !== undefined ? el.value : el.textContent;
  }

  function valueOf(params) {
    const { el } = resolveRef(params.ref);
    const target = editableTarget(el) || { el };
    return { value: readValue(target.el) };
  }

  /// Sets a value directly, for the input types where synthesised keystrokes do
  /// not apply (date, color, range, number spinners) or when the caller asked
  /// for a plain assignment. Fires the events frameworks listen for.
  function setValue(params) {
    const { el, fromEarlierSnapshot } = resolveRef(params.ref);
    const target = editableTarget(el);
    if (!target) throw new BridgeError('unsupported', `element ${params.ref} does not accept a value`);
    const field = target.el;
    if (target.kind === 'input') {
      const proto = tagOf(field) === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      setter.call(field, params.value);
    } else {
      field.textContent = params.value;
    }
    field.dispatchEvent(new Event('input', { bubbles: true }));
    field.dispatchEvent(new Event('change', { bubbles: true }));
    return { value: readValue(field), fromEarlierSnapshot, description: describeElement(el) };
  }

  function selectOption(params) {
    const { el, fromEarlierSnapshot } = resolveRef(params.ref);
    let select = el;
    if (tagOf(select) !== 'select') select = el.querySelector && el.querySelector('select');
    if (!select) {
      throw new BridgeError('unsupported', `element ${params.ref} is not a <select>`, [
        'For custom dropdowns, click the combobox and then click the option from a fresh snapshot.'
      ]);
    }
    if (isDisabled(select)) throw new BridgeError('unsupported', `element ${params.ref} is disabled`);
    const wanted = params.values || [];
    const options = Array.from(select.options);
    const matched = [];
    const missing = [];
    for (const want of wanted) {
      const found = options.find(o => o.value === want) || options.find(o => normalize(o.label || o.textContent) === want)
        || options.find(o => normalize(o.label || o.textContent).toLowerCase() === want.toLowerCase());
      if (found) matched.push(found); else missing.push(want);
    }
    if (missing.length) {
      throw new BridgeError('element_not_found', `no option matches ${missing.map(m => `'${m}'`).join(', ')}`, [
        'Options are matched by value or by visible label; the snapshot lists them under the combobox.',
        `Available: ${options.slice(0, 40).map(o => `'${normalize(o.label || o.textContent)}'`).join(', ')}${options.length > 40 ? ', …' : ''}`
      ]);
    }
    if (!select.multiple && matched.length > 1) throw new BridgeError('invalid_argument', 'this select accepts a single value');
    for (const o of options) o.selected = false;
    for (const o of matched) o.selected = true;
    select.dispatchEvent(new Event('input', { bubbles: true }));
    select.dispatchEvent(new Event('change', { bubbles: true }));
    return {
      selected: Array.from(select.selectedOptions).map(o => normalize(o.label || o.textContent)),
      fromEarlierSnapshot,
      description: describeElement(el)
    };
  }

  /// Focuses any focusable element without clicking it, for keys aimed at
  /// buttons, checkboxes, links and the like.
  function focusElement(params) {
    const { el, fromEarlierSnapshot } = resolveRef(params.ref);
    scrollIntoViewIfNeeded(el);
    const target = isFocusable(el) ? el : (el.querySelector && el.querySelector('input, button, select, textarea, a[href], [tabindex]')) || el;
    try { target.focus({ preventScroll: true }); } catch (_) { /* not focusable */ }
    const active = document.activeElement;
    return { focused: active === target || (target.contains && target.contains(active)), fromEarlierSnapshot, description: describeElement(el) };
  }

  function jsClick(params) {
    const { el, fromEarlierSnapshot } = resolveRef(params.ref);
    scrollIntoViewIfNeeded(el);
    el.click();
    return { fromEarlierSnapshot, description: describeElement(el) };
  }

  function tagElement(params) {
    const { el } = resolveRef(params.ref);
    if (params.nonce) el.setAttribute('data-amcu-target', params.nonce);
    else el.removeAttribute('data-amcu-target');
    return { ok: true };
  }

  function pageText() {
    const body = document.body;
    return { text: body ? body.innerText : '', url: location.href, title: document.title, readyState: document.readyState };
  }

  // ---------------------------------------------------------------------------
  // Dispatch

  async function handle(message) {
    switch (message.op) {
      case 'ping':
        return { ok: true, version: VERSION, url: location.href, isTop: window === window.top };
      case 'snapshot':
        return snapshot(message.params || {});
      case 'measure':
        return measure(message.params);
      case 'focus-for-input':
        return focusForInput(message.params);
      case 'value':
        return valueOf(message.params);
      case 'set-value':
        return setValue(message.params);
      case 'select-option':
        return selectOption(message.params);
      case 'js-click':
        return jsClick(message.params);
      case 'focus':
        return focusElement(message.params);
      case 'tag-element':
        return tagElement(message.params);
      case 'page-text':
        return pageText();
      case 'describe': {
        const { el, fromEarlierSnapshot } = resolveRef(message.params.ref);
        return { description: describeElement(el), fromEarlierSnapshot };
      }
      default:
        throw new BridgeError('unsupported', `unknown content op '${message.op}'`);
    }
  }

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || message.__amcu !== true) return false;
    Promise.resolve()
      .then(() => handle(message))
      .then(result => sendResponse({ ok: true, result }))
      .catch(error => {
        const payload = error instanceof BridgeError
          ? error.toJSON()
          : { code: 'page_error', message: String(error && error.message || error), nextSteps: [] };
        sendResponse({ ok: false, error: payload });
      });
    return true;
  });

  globalThis.__amcu = { version: VERSION, state, snapshot };
})();
