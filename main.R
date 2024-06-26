# Statement ---
# 分析人们对食用鹿肉的看法，及其影响因素。

# Preparation ----
pacman::p_load(
  openxlsx, dplyr, tidytext, stopwords, topicmodels, ggplot2, ggsci, 
  DescTools, showtext
)
showtext_auto()

# Data ----
# 问卷调查吃鹿肉态度得分、性别、对狩猎的态度分数等。
survey <- 
  read.xlsx("data_raw/kyoto_vension_raw.xlsx", sheet = "Num") %>% 
  tibble() %>% 
  rename_with(~ tolower(.x)) %>% 
  rename(id = "no.") %>% 
  mutate(
    id = as.character(id), 
    ven = as.character(q10), 
    hunting = as.integer(q11b)
  ) %>% 
  select(id, gender, age, education, ven, hunting) %>% 
  # 加入Q10日语回答信息。
  left_join(
    read.xlsx("data_raw/kyoto_vension_raw.xlsx", sheet = "Text") %>%
      select(id = "No.", ven_reason = "Q10") %>% 
      mutate(id = as.character(id)), 
    by = "id"
  ) %>% 
  filter(
    !is.na(ven_reason), !is.na(ven), !is.na(hunting), 
    !is.na(gender), gender != 2, !is.na(age)
  ) %>% 
  # 删除不符合要求的回答。383号受访者的回答是“わからない”。725号的回答是“Don't have any information about it .so,I can't say”。
  filter(id != "383", id != "725") %>% 
  # 将部分非日文文本翻译成日文。食用ChatGPT 3.5进行翻译，指令为“Translate the text to Japanese: [text]”。
  mutate(ven_reason = case_when(
    ven_reason == "没有这个习惯…像是要吃狗肉一样不舒服" ~ 
      "この習慣がないから…犬の肉を食べるみたいに気持ち悪い", 
    ven_reason == "鹿鹿那么可爱怎么可以吃鹿鹿~" ~ 
      "鹿はこんなに可愛いのに、どうして鹿を食べられるの？", 
    TRUE ~ ven_reason
  ))

# Correlation ----
## Vension score ~ attributes ----
# 吃鹿肉态度～性别：朱珠已进行了卡方分析，此处基于每个受访者数据进行组间对比。
by(as.numeric(survey$ven), survey$gender, shapiro.test)
# 男女组均不符合正态分布，因此用非参数方法进行组间对比。
kruskal.test(as.numeric(survey$ven) ~ survey$gender)
# 结论：不同性别之间吃鹿肉态度有差异。

# 吃鹿肉态度～年龄组：大部分年龄组不符合正态分布，因此用非参数方法。
by(as.numeric(survey$ven), survey$age, shapiro.test)
kruskal.test(as.numeric(survey$ven) ~ survey$age)

# 吃鹿肉态度～教育水平。
lapply(
  as.character(1:4), 
  function(x) {
    filter(survey, education == x)$ven %>% 
      as.numeric() %>% 
      shapiro.test()
  }
)
kruskal.test(as.numeric(survey$ven) ~ survey$education)

## Hunting score ~ attributes ----
# 狩猎态度～性别。
by(as.numeric(survey$hunting), survey$gender, shapiro.test)
kruskal.test(as.numeric(survey$hunting) ~ survey$gender)

# 狩猎态度～年龄组。
by(as.numeric(survey$hunting), survey$age, shapiro.test)
kruskal.test(as.numeric(survey$hunting) ~ survey$age)

# 狩猎态度～教育水平。
lapply(
  as.character(1:4), 
  function(x) {
    filter(survey, education == x)$hunting %>% 
      as.numeric() %>% 
      shapiro.test()
  }
)
kruskal.test(as.numeric(survey$hunting) ~ survey$education)

## Vension score ~ hunting score ----
cor.test(as.numeric(survey$ven), as.numeric(survey$hunting))

# Text mining ----
# 停止词：在分词之后去除的不重要的日语词汇。
jp_stop_word <- tibble(
  word = c(
    stopwords("ja", source = "marimo"), 
    # Hiragana in Japanese: define Unicode code points for hiragana characters and convert code points to UTF-8 characters. 
    strsplit(intToUtf8(c(12353:12435)), "")[[1]], 
    "amp", "ます", "です", "こと", "って", "てい", "という", "んで", "ので", 
    "なく", "など", "なる", "せん", "しま", "とか", "しょう", "ろう", "けど", 
    "さん", "あっ", "られる", "ぜひ", "てる", "なら", "思い", "思う", "れる"
  )
)

# 分词：文本分析的基础，将文档分成一个个单独的词。
tok <- unnest_tokens(survey, word, ven_reason) %>% 
  # 去除停止词。
  anti_join(jp_stop_word, by = "word") %>% 
  count(id, word, sort = TRUE)

# 计算分词的TF-IDF：一个词语如果在一个文档中出现次数越多，通常越重要；但是如果它在其他所有文档中都出现，那就不重要；只有在某个文档中出现次数多，且其他文档中少出现的词才得高分。
tf_idf <- tok %>% 
  bind_tf_idf(word, id, n) %>% 
  arrange(desc(tf_idf)) 

## Topic model ----
# 生成term-document矩阵。
dtm <- cast_dtm(tf_idf, id, word, n)

# 要选取几个主题呢？当话题数量太少时，大部分人的回答属于各个主题的概率差不多，这显然不合理；主题数很多时，各个回答属于各个话题的概率会更加有区分度，但是主题也不应太多。
# 函数：基于自定义主题数量，获得各个文档属于不同主题的概率。
test_k_topic <- function(k_x) {
  # 生成LDA数据。
  lda <- LDA(dtm, k_x, control = list(seed = 1234))
  
  # 各篇文章属于各个主题的概率。
  id_topic_res <- tidy(lda, matrix = "gamma") %>% 
    mutate(k = k_x)
  return(id_topic_res)
}
# 测试主题数量思路：如果区分度越高的话，一个文档被划分到各个主题下的概率就越离散，基尼系数就越高。所以，可以给定一定范围的自定义主题数量，计算不同主题数量下，各个文档被划分到各个主题中的概率。看在那个自定义主题数量下，平均基尼系数最高，或者看看基尼系数在什么时候突变。
# 要测试的自定义主题数量范围。
range_k <- 2:20
# 存储测试结果。
id_topic_test <- 
  lapply(range_k, test_k_topic) %>% 
  setNames(as.character(range_k)) %>% 
  bind_rows() %>% 
  rename(id = document)
# 计算基尼系数之前，先直观观察不同主题下文档主题划分的区分度。如果区分度越高，格子之间的颜色差异就越明显。
id_topic_test %>% 
  bind_rows() %>% 
  ggplot() + 
  geom_tile(aes(id, as.integer(topic), fill = gamma)) + 
  scale_fill_gradient(high = "red", low = "green") + 
  theme(axis.text.x = element_blank()) + 
  facet_wrap(.~ k, scales = "free_y")
# 计算基尼系数并比较不同自定义主题数量下基尼系数的差异。
id_topic_test %>% 
  group_by(k, id) %>% 
  summarise(gini = Gini(gamma)) %>% 
  ungroup() %>% 
  mutate(k = factor(k, levels = as.character(range_k))) %>% 
  ggplot() + 
  geom_boxplot(aes(k, gini)) + 
  theme_bw() + 
  labs(x = "Topic number", y = "Gini")

# 正式进行主题模型分析。
# 获得测试范围内的最佳自定义主题数量：基尼系数最大，区分度最高。
# 计算突变点：平均基尼系数突然增加的点对应的主题数，就是目标主题数。
gini_chg_rate <- id_topic_test %>% 
  group_by(k, document) %>% 
  summarise(gini = Gini(gamma), .groups = "drop") %>% 
  group_by(k) %>% 
  summarise(gini = mean(gini), .groups = "drop") %>% 
  mutate(
    gini_lag = lag(gini), gini_mean_chg_rate = (gini - gini_lag) / gini_lag
  )
ggplot(gini_chg_rate) + 
  geom_point(aes(k, gini_mean_chg_rate))
(
  tar_k <- gini_chg_rate %>% 
    filter(gini_mean_chg_rate == max(gini_mean_chg_rate, na.rm = TRUE)) %>% 
    pull(k)
)

# 构建LDA数据。
lda <- LDA(dtm, k = tar_k, control = list(seed = 1234))

# 评估区分度。
# 每个回答属于各个主题的概率。
id_topic <- tidy(lda, matrix = "gamma") %>% 
  # 计算基尼系数。
  rename(id = document) %>% 
  group_by(id) %>% 
  mutate(gini = Gini(gamma)) %>% 
  ungroup() %>% 
  # 区分回答：有偏向型的还是均衡型的。基尼系数越高，回答越偏向某个主题，系数越低，回答和多个主题相关的可能性越大。
  mutate(gini_cls = case_when(
    gini <= quantile(gini, 1/3) ~ "1", 
    gini <= quantile(gini, 2/3) ~ "2", 
    gini <= quantile(gini, 3/3) ~ "3"
  ))
# 基尼系数越高的组，概率越离散。
id_topic %>% 
  ggplot() + 
  geom_tile(aes(id, topic, fill = gamma)) + 
  facet_wrap(.~ gini_cls, scales = "free_x", ncol = 1) + 
  theme(axis.text.x = element_blank()) + 
  scale_fill_gradient(high = "red", low = "green")

# 转化成可阅读的主题数据，并取每个主题的前几位关键词。
# 漏洞：需要再增加停止词，并且统一日语词汇如“鹿”和“しか”。
tidy(lda, matrix = "beta") %>% 
  group_by(topic) %>% 
  slice_max(beta, n = 15) %>% 
  mutate(term = reorder_within(term, beta, topic)) %>% 
  summarise(term = list(term), .groups = "drop") %>% 
  mutate(
    term = unlist(lapply(term, function(x) paste0(x, collapse = ", ")))
  ) %>% 
  mutate(term = gsub("_", "", term), term = gsub("[0-9]", "", term))

# 抽出和各个主题匹配度最高的前10条回答，解读各个主题的含义。
id_topic %>% 
  group_by(topic) %>% 
  arrange(topic, -gamma) %>% 
  slice_head(n = 10) %>% 
  ungroup() %>% 
  # 漏洞：需要提前更改id的类型。
  left_join(mutate(survey, id = as.character(id)), by = "id") %>% 
  select(id, topic, ven_reason) 
# 用于获得某个主题下纯文档原文数据的代码如下。
# id_topic %>% 
#   group_by(topic) %>% 
#   arrange(topic, -gamma) %>% 
#   slice_head(n = 10) %>% 
#   ungroup() %>% 
#   # 漏洞：需要提前更改id的类型。
#   left_join(mutate(survey, id = as.character(id)), by = "id") %>% 
#   select(id, topic, ven_reason) %>% 
#   filter(topic == 6) %>% 
#   pull(ven_reason) %>% 
#   cat(sep = "\n")

# 漏洞：待办：抽出和各个主题匹配度最高的前20名，让其他人试着根据预定义进行分类；抽出混合主题的回答，让其他人试着进行归类。

## Score ~ topic ----
# 对狩猎的态度和对食用鹿肉的态度之间的关系。
survey %>% 
  group_by(ven, hunting) %>% 
  summarise(n = n(), .groups = "drop") %>% 
  ggplot() + 
  geom_col(aes(hunting, n, fill = ven), position = "fill")
# 漏洞：注意：极度反感狩猎和极度喜欢狩猎的人都比较支持食用鹿肉，为什么呢？

# 食用鹿肉打分和主题的关系。
# 从两个角度看主题和得分的关系。
id_topic %>% 
  left_join(select(survey, id, ven), by = "id") %>% 
  # 漏洞：应该早点把383号删除。
  filter(id != "383") %>% 
  group_by(ven, topic) %>% 
  summarise(gamma = sum(gamma), .groups = "drop") %>% 
  ggplot() + 
  geom_col(aes(ven, gamma, fill = as.character(topic)), position = "fill") + 
  theme_bw() + 
  scale_fill_d3() + 
  labs(x = "Ven", y = "Proportion", fill = "Topic") +
  theme(axis.text.x = element_text(angle = 90))

id_topic %>% 
  left_join(select(survey, id, ven), by = "id") %>% 
  # 漏洞：应该早点把383号删除。
  filter(id != "383") %>% 
  group_by(ven, topic) %>% 
  summarise(gamma = sum(gamma), .groups = "drop") %>% 
  ggplot() + 
  geom_col(aes(topic, gamma, fill = as.character(ven)), position = "fill") + 
  theme_bw() + 
  scale_fill_d3() + 
  labs(x = "Topic", y = "Proportion", fill = "Ven") +
  theme(axis.text.x = element_text(angle = 90))

# 对狩猎的态度和主题的关系。
id_topic %>% 
  left_join(select(survey, id, hunting), by = "id") %>% 
  # 漏洞：应该早点把383号删除。
  filter(id != "383") %>% 
  group_by(hunting, topic) %>% 
  summarise(gamma = sum(gamma), .groups = "drop") %>% 
  ggplot() + 
  geom_col(
    aes(hunting, gamma, fill = as.character(topic)), position = "fill"
  ) + 
  theme_bw() + 
  scale_fill_d3() + 
  labs(x = "Hunting", y = "Proportion", fill = "Topic") +
  theme(axis.text.x = element_text(angle = 90))

id_topic %>% 
  left_join(select(survey, id, hunting), by = "id") %>% 
  # 漏洞：应该早点把383号删除。
  filter(id != "383") %>% 
  group_by(hunting, topic) %>% 
  summarise(gamma = sum(gamma), .groups = "drop") %>% 
  ggplot() + 
  geom_col(
    aes(topic, gamma, fill = as.character(hunting)), position = "fill"
  ) + 
  theme_bw() + 
  scale_fill_d3() + 
  labs(x = "Topic", y = "Proportion", fill = "Hunting") +
  theme(axis.text.x = element_text(angle = 90))

