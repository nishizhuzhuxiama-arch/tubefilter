import Foundation

/// 注入到网页里的脚本。
///
/// 职责边界：
/// - JS 只做「采集」和「执行」，不做任何判断。所有屏蔽判定都在 Swift 侧完成，
///   这样规则、统计、历史三者只有一个真相来源。
/// - 采集与执行都通过 CSS 类完成，不直接写内联样式，避免被页面自身的样式覆盖。
enum InjectedScript {

    /// 生成完整脚本：配置头 + 主体。
    static func source(configJSON: String) -> String {
        return "window.__tf_config = " + configJSON + ";\n" + core
    }

    /// 主体脚本。使用原始字符串，保证 JS 正则里的反斜杠不会被 Swift 解释。
    static let core: String = #"""
    (function () {
      if (window.__tf_installed) {
        if (typeof window.__tf_rescan === 'function') { window.__tf_rescan(); }
        return;
      }
      window.__tf_installed = true;

      var CFG = window.__tf_config || {};
      var HANDLER = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tf) || null;

      var cardsByID = {};
      var verdicts = {};
      var fingerprints = {};
      var scanTimer = null;
      var pendingScan = false;
      var lastPageType = '';

      var CARD_SELECTORS = [
        'ytd-rich-item-renderer',
        'ytd-video-renderer',
        'ytd-compact-video-renderer',
        'ytd-grid-video-renderer',
        'ytd-playlist-video-renderer',
        'ytd-reel-item-renderer',
        'ytd-rich-grid-media',
        'yt-lockup-view-model',
        'ytm-video-with-context-renderer',
        'ytm-compact-video-renderer',
        'ytm-media-item'
      ];

      var AD_SELECTORS = [
        'ytd-promoted-sparkles-web-renderer',
        'ytd-promoted-video-renderer',
        'ytd-display-ad-renderer',
        'ytd-ad-slot-renderer',
        'ytd-in-feed-ad-layout-renderer',
        'ytd-banner-promo-renderer',
        'ytd-statement-banner-renderer',
        'ytd-compact-promoted-video-renderer',
        'ytm-promoted-sparkles-web-renderer',
        'ytm-companion-slot',
        '#player-ads',
        '#masthead-ad',
        '.ytp-ad-module',
        '.ytp-ad-overlay-slot'
      ];

      var WATCH_RECOMMEND_SELECTORS = [
        '#secondary',
        '#related',
        'ytd-watch-next-secondary-results-renderer',
        'ytd-compact-autoplay-renderer',
        'ytd-single-column-watch-next-results-renderer',
        '.ytp-autonav-endscreen',
        '.ytp-ce-element'
      ];

      var COMMENT_SELECTORS = [
        '#comments',
        'ytd-comments'
      ];

      var SHORTS_SHELF_SELECTORS = [
        'ytd-reel-shelf-renderer',
        'ytm-reel-shelf-renderer',
        'ytd-rich-shelf-renderer[is-shorts]',
        'grid-shelf-view-model'
      ];

      var TITLE_SELECTORS = [
        '#video-title-link',
        'a#video-title',
        '#video-title',
        'h3 a span',
        'h3 a',
        'h3 span',
        '.yt-lockup-metadata-view-model__title',
        '.media-item-headline',
        '.yt-core-attributed-string'
      ];

      var CHANNEL_NAME_SELECTORS = [
        'ytd-channel-name a',
        '#channel-name a',
        '#channel-info a',
        '#text.ytd-channel-name',
        'yt-formatted-string.ytd-channel-name',
        '.yt-content-metadata-view-model-wiz__metadata-text',
        '.yt-content-metadata-view-model__metadata-row a'
      ];

      var DURATION_SELECTORS = [
        'ytd-thumbnail-overlay-time-status-renderer #text',
        'ytd-thumbnail-overlay-time-status-renderer span',
        '#text.ytd-thumbnail-overlay-time-status-renderer',
        '.badge-shape-wiz__text',
        '#time-status span',
        'ytm-thumbnail-overlay-time-status-renderer'
      ];

      function post(payload) {
        if (!HANDLER) { return; }
        try { HANDLER.postMessage(payload); } catch (error) { }
      }

      function injectStyle() {
        if (document.getElementById('tf-style')) { return; }
        var style = document.createElement('style');
        style.id = 'tf-style';
        style.textContent = [
          '.tf-removed { display: none !important; }',
          '.tf-blocked { display: none !important; }',
          '.tf-placeholder.tf-blocked { display: block !important; }',
          '.tf-placeholder > *:not(.tf-banner) { display: none !important; }',
          '.tf-banner { display: block !important; padding: 10px 12px; margin: 4px 0;',
          '  font: 400 13px/1.5 -apple-system, "PingFang SC", sans-serif;',
          '  color: #6b6b6b; background: #f4f4f5; border: 1px solid #e3e3e5;',
          '  border-radius: 10px; word-break: break-all; }'
        ].join('\n');
        (document.head || document.documentElement).appendChild(style);
      }

      function removeMatching(selectors, tag) {
        if (!selectors || !selectors.length) { return; }
        var nodes;
        try { nodes = document.querySelectorAll(selectors.join(',')); } catch (error) { return; }
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          if (node.classList.contains('tf-removed')) { continue; }
          node.classList.add('tf-removed');
        }
      }

      function applyPageCleanups() {
        injectStyle();
        if (CFG.removeAds !== false) { removeMatching(AD_SELECTORS, 'ad'); }
        if (CFG.removeWatchRecommendations) { removeMatching(WATCH_RECOMMEND_SELECTORS, 'rec'); }
        if (CFG.removeComments) { removeMatching(COMMENT_SELECTORS, 'comment'); }
        if (CFG.removeHomeShelves || CFG.blockShorts) { removeMatching(SHORTS_SHELF_SELECTORS, 'shorts'); }
      }

      function pickText(root, selectors) {
        for (var i = 0; i < selectors.length; i++) {
          var element;
          try { element = root.querySelector(selectors[i]); } catch (error) { continue; }
          if (!element) { continue; }
          var text = (element.textContent || '').replace(/\s+/g, ' ').trim();
          if (text) { return text; }
        }
        return '';
      }

      function currentPageType() {
        var path = location.pathname || '';
        if (path === '/' || path.indexOf('/index') === 0) { return 'home'; }
        if (path.indexOf('/feed/subscriptions') === 0) { return 'subscriptions'; }
        if (path.indexOf('/feed/trending') === 0) { return 'trending'; }
        if (path.indexOf('/feed/explore') === 0) { return 'explore'; }
        if (path.indexOf('/results') === 0) { return 'search'; }
        if (path.indexOf('/watch') === 0) { return 'watch'; }
        if (path.indexOf('/shorts') === 0) { return 'shorts'; }
        if (path.indexOf('/playlist') === 0) { return 'playlist'; }
        if (path.indexOf('/@') === 0 || path.indexOf('/channel/') === 0 || path.indexOf('/c/') === 0) { return 'channel'; }
        return 'other';
      }

      function hasCardAncestor(element) {
        var current = element.parentElement;
        var depth = 0;
        while (current && depth < 12) {
          if (current.tagName) {
            var tag = current.tagName.toLowerCase();
            for (var i = 0; i < CARD_SELECTORS.length; i++) {
              if (CARD_SELECTORS[i] === tag) { return true; }
            }
          }
          current = current.parentElement;
          depth++;
        }
        return false;
      }

      function isInsideAdContainer(element) {
        var current = element;
        var depth = 0;
        while (current && depth < 8) {
          if (current.tagName) {
            var tag = current.tagName.toLowerCase();
            for (var i = 0; i < AD_SELECTORS.length; i++) {
              var selector = AD_SELECTORS[i];
              if (selector.charAt(0) === '#') {
                if (current.id === selector.substring(1)) { return true; }
              } else if (selector.charAt(0) === '.') {
                if (current.classList && current.classList.contains(selector.substring(1))) { return true; }
              } else if (tag === selector) {
                return true;
              }
            }
          }
          current = current.parentElement;
          depth++;
        }
        return false;
      }

      function videoIdentity(card) {
        var link = card.querySelector('a[href*="/watch?v="]');
        if (!link) { link = card.querySelector('a[href*="/shorts/"]'); }
        if (link) {
          var href = link.getAttribute('href') || '';
          var match = href.match(/[?&]v=([A-Za-z0-9_-]{6,})/);
          if (match) { return { id: match[1], url: '/watch?v=' + match[1] }; }
          match = href.match(/\/shorts\/([A-Za-z0-9_-]{6,})/);
          if (match) { return { id: match[1], url: '/shorts/' + match[1] }; }
        }
        var attribute = card.getAttribute('data-video-id') || card.getAttribute('video-id') || '';
        if (attribute) { return { id: attribute, url: '/watch?v=' + attribute }; }
        return null;
      }

      function channelInfo(card) {
        var name = pickText(card, CHANNEL_NAME_SELECTORS);
        var identifier = '';
        var link = card.querySelector('a[href^="/@"], a[href*="/channel/"], a[href*="/c/"], a[href*="/user/"]');
        if (link) {
          var href = link.getAttribute('href') || '';
          var match = href.match(/\/(channel|user)\/([A-Za-z0-9_-]+)/);
          identifier = match ? match[2] : href.replace(/^\//, '');
          if (!name) { name = (link.textContent || '').replace(/\s+/g, ' ').trim(); }
        }
        return { name: name, id: identifier };
      }

      function badgesOf(card) {
        var badges = [];
        var collected = '';
        var selectors = ['badge-shape', 'ytd-badge-supported-renderer', 'yt-thumbnail-badge-view-model', '.badge-shape-wiz'];
        for (var i = 0; i < selectors.length; i++) {
          var nodes;
          try { nodes = card.querySelectorAll(selectors[i]); } catch (error) { continue; }
          for (var j = 0; j < nodes.length; j++) {
            collected += ' ' + (nodes[j].textContent || '');
          }
        }
        var text = collected.toLowerCase();
        if (text.indexOf('member') >= 0 || text.indexOf('会员') >= 0) { badges.push('member'); }
        if (text.indexOf('premium') >= 0) { badges.push('premium'); }
        if (text.indexOf('live') >= 0 || text.indexOf('直播') >= 0) { badges.push('live'); }
        if (text.indexOf('upcoming') >= 0 || text.indexOf('首播') >= 0 || text.indexOf('预告') >= 0) { badges.push('upcoming'); }
        if (text.indexOf('shorts') >= 0 || text.indexOf('短视频') >= 0) { badges.push('shorts'); }
        var url = (card.querySelector('a[href*="/shorts/"]') ? '/shorts/' : '');
        if (url && badges.indexOf('shorts') < 0) { badges.push('shorts'); }
        return badges;
      }

      function durationSeconds(card) {
        var raw = pickText(card, DURATION_SELECTORS);
        if (!raw) { return 0; }
        var match = raw.match(/(\d{1,2}:)?\d{1,2}:\d{2}/);
        if (!match) { return 0; }
        var parts = match[0].split(':');
        var seconds = 0;
        for (var i = 0; i < parts.length; i++) { seconds = seconds * 60 + parseInt(parts[i], 10); }
        return seconds;
      }

      function topicsOf(card) {
        var topics = [];
        var nodes;
        try { nodes = card.querySelectorAll('a[href*="/hashtag/"]'); } catch (error) { return topics; }
        for (var i = 0; i < nodes.length && topics.length < 8; i++) {
          var text = (nodes[i].textContent || '').replace(/\s+/g, ' ').trim().replace(/^#/, '');
          if (text) { topics.push(text); }
        }
        var meta = pickText(card, ['#metadata-line', '.yt-content-metadata-view-model__metadata-row']);
        if (meta) { topics.push(meta); }
        return topics;
      }

      function collectCards() {
        var result = [];
        var all;
        try { all = document.querySelectorAll(CARD_SELECTORS.join(',')); } catch (error) { return result; }
        for (var i = 0; i < all.length; i++) {
          var element = all[i];
          if (isInsideAdContainer(element)) { continue; }
          if (hasCardAncestor(element)) { continue; }
          result.push(element);
        }
        return result;
      }

      function applyToCard(card, verdict) {
        if (verdict.blocked) {
          card.classList.add('tf-blocked');
        } else {
          card.classList.remove('tf-blocked');
        }
        var existing = card.querySelector('.tf-banner');
        if (verdict.blocked && CFG.showPlaceholder) {
          card.classList.add('tf-placeholder');
          if (!existing) {
            existing = document.createElement('div');
            existing.className = 'tf-banner';
            card.insertBefore(existing, card.firstChild);
          }
          var label = '已屏蔽 · ' + (verdict.reasonTitle || '命中规则');
          if (verdict.detail) { label = label + ' · ' + verdict.detail; }
          existing.textContent = label;
        } else {
          card.classList.remove('tf-placeholder');
          if (existing && existing.parentNode) { existing.parentNode.removeChild(existing); }
        }
      }

      function applyVerdict(verdict) {
        if (!verdict || !verdict.videoID) { return; }
        verdicts[verdict.videoID] = verdict;
        var cards = cardsByID[verdict.videoID] || [];
        for (var i = 0; i < cards.length; i++) {
          if (!cards[i].isConnected) { continue; }
          applyToCard(cards[i], verdict);
        }
      }

      function reapplyAll() {
        for (var id in verdicts) {
          if (!Object.prototype.hasOwnProperty.call(verdicts, id)) { continue; }
          var cards = cardsByID[id] || [];
          for (var i = 0; i < cards.length; i++) {
            if (!cards[i].isConnected) { continue; }
            applyToCard(cards[i], verdicts[id]);
          }
        }
      }

      function scan() {
        if (CFG.enabled === false) { return; }
        applyPageCleanups();

        var pageType = currentPageType();
        if (pageType !== lastPageType) {
          lastPageType = pageType;
          post({ type: 'page', pageType: pageType, url: location.href });
        }

        var cards = collectCards();
        var batch = [];
        var batchIDs = {};

        for (var i = 0; i < cards.length && batch.length < 160; i++) {
          var card = cards[i];
          var identity = videoIdentity(card);
          if (!identity) { continue; }

          if (!cardsByID[identity.id]) { cardsByID[identity.id] = []; }
          if (cardsByID[identity.id].indexOf(card) < 0) { cardsByID[identity.id].push(card); }

          var title = pickText(card, TITLE_SELECTORS);
          if (!title) { continue; }

          var channel = channelInfo(card);
          var duration = durationSeconds(card);
          var fingerprint = [identity.id, title, channel.name, duration].join('|');
          if (fingerprints[identity.id] === fingerprint) { continue; }
          fingerprints[identity.id] = fingerprint;
          if (batchIDs[identity.id]) { continue; }
          batchIDs[identity.id] = true;

          batch.push({
            videoID: identity.id,
            title: title,
            channelName: channel.name,
            channelID: channel.id,
            badges: badgesOf(card),
            durationSeconds: duration,
            viewCountText: '',
            topics: topicsOf(card),
            url: identity.url,
            source: pageType
          });
        }

        if (batch.length) {
          post({ type: 'items', pageType: pageType, url: location.href, items: batch });
        }
        reapplyAll();
      }

      function scheduleScan() {
        if (pendingScan) { return; }
        pendingScan = true;
        if (scanTimer) { clearTimeout(scanTimer); }
        scanTimer = setTimeout(function () {
          pendingScan = false;
          scan();
        }, 500);
      }

      window.__tf_apply = function (payload) {
        if (!payload) { return; }
        if (payload.showPlaceholder !== undefined) { CFG.showPlaceholder = payload.showPlaceholder; }
        if (payload.removeAds !== undefined) { CFG.removeAds = payload.removeAds; }
        if (payload.removeWatchRecommendations !== undefined) { CFG.removeWatchRecommendations = payload.removeWatchRecommendations; }
        if (payload.removeComments !== undefined) { CFG.removeComments = payload.removeComments; }
        if (payload.removeHomeShelves !== undefined) { CFG.removeHomeShelves = payload.removeHomeShelves; }
        if (payload.blockShorts !== undefined) { CFG.blockShorts = payload.blockShorts; }
        var list = payload.verdicts || [];
        for (var i = 0; i < list.length; i++) { applyVerdict(list[i]); }
      };

      window.__tf_updateConfig = function (config) {
        if (!config) { return; }
        for (var key in config) {
          if (Object.prototype.hasOwnProperty.call(config, key)) { CFG[key] = config[key]; }
        }
        applyPageCleanups();
        scan();
      };

      window.__tf_clearVerdicts = function () {
        verdicts = {};
        var nodes = document.querySelectorAll('.tf-blocked');
        for (var i = 0; i < nodes.length; i++) {
          nodes[i].classList.remove('tf-blocked');
          nodes[i].classList.remove('tf-placeholder');
        }
      };

      window.__tf_rescan = scan;

      function installObservers() {
        if (!document.body) { return; }
        var observer = new MutationObserver(function () { scheduleScan(); });
        observer.observe(document.body, { childList: true, subtree: true });

        window.addEventListener('yt-navigate-finish', function () { scheduleScan(); });
        window.addEventListener('popstate', function () { scheduleScan(); });
        window.addEventListener('scroll', function () { scheduleScan(); }, { passive: true });
      }

      function boot() {
        injectStyle();
        installObservers();
        scan();
        post({ type: 'ready', pageType: currentPageType(), url: location.href });
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
      } else {
        boot();
      }

      setTimeout(function () { scheduleScan(); }, 1200);
      setTimeout(function () { scheduleScan(); }, 3000);
    })();
    """#
}
