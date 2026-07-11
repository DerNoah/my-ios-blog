---
layout: default
title: My iOS Journey
permalink: /
---

{% include biography.md %}

## CV

- [Lebenslauf (Deutsch, PDF)](/assets/cv/noah-pluetzer-lebenslauf-de.pdf)
- [Resume (English, PDF)](/assets/cv/noah-pluetzer-resume-en.pdf)

## Articles

{% assign articles = site.pages | where: "layout", "post" | sort: "date" | reverse %}
{% for article in articles %}
- [{{ article.title }}]({{ article.url | relative_url }}){% if article.subtitle %} — {{ article.subtitle }}{% endif %}
{% endfor %}
