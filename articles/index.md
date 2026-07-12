---
layout: default
title: Articles
permalink: /articles/
---

<section class="page-heading wrap">
  <h1>Articles</h1>
  <p>Deep dives into iOS problems that aren’t well documented.</p>
</section>

<section class="grid-wrap wrap">
  <div class="article-grid">
    {% assign articles = site.pages | where: "layout", "post" | sort: "date" | reverse %}
    {% for article in articles %}
      {% include article-card.html article=article %}
    {% endfor %}
  </div>
</section>
