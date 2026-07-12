// Adds the language label + Copy button chrome to Rouge code blocks.
(function () {
  document.querySelectorAll('.post-content div.highlighter-rouge').forEach(function (block) {
    var langMatch = block.className.match(/language-([a-z0-9+#-]+)/i);
    var lang = langMatch ? langMatch[1] : 'code';
    if (lang === 'plaintext') lang = 'text';

    var head = document.createElement('div');
    head.className = 'code-head';

    var label = document.createElement('span');
    label.className = 'code-lang';
    label.textContent = lang;

    var copy = document.createElement('button');
    copy.className = 'code-copy';
    copy.type = 'button';
    copy.textContent = 'Copy';
    copy.addEventListener('click', function () {
      var code = block.querySelector('pre code') || block.querySelector('pre');
      navigator.clipboard.writeText(code.textContent).then(function () {
        copy.textContent = 'Copied';
        setTimeout(function () { copy.textContent = 'Copy'; }, 1600);
      });
    });

    head.appendChild(label);
    head.appendChild(copy);
    block.insertBefore(head, block.firstChild);
  });
})();
