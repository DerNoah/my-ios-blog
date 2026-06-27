---
layout: default
title: My iOS Journey
permalink: /
---

{% include biography.md %}

## Articles

{% assign articles = site.pages | where: "layout", "post" | sort: "date" | reverse %}
{% for article in articles %}
- [{{ article.title }}]({{ article.url | relative_url }}){% if article.subtitle %} — {{ article.subtitle }}{% endif %}
{% endfor %}
