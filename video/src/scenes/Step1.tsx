import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import search from '../data/term/search.json';
import {Background} from '../components/Background';
import {Browser} from '../components/Browser';
import {Code} from '../components/Code';
import {StepBar} from '../components/StepBar';
import {Terminal} from '../components/Terminal';
import {Pill} from '../components/Brand';
import {enter, t01} from '../components/anim';
import {cue} from '../timeline';
import {C, FPS, sans} from '../theme';

const SQL = `CREATE FUNCTION shop.search(user_id text, user_traits jsonb, q text, n int)
RETURNS TABLE (product_id int, title text, arm text) LANGUAGE sql STABLE AS $$
  WITH v AS MATERIALIZED (           -- evaluated once per request
    SELECT flagsmith.variant('search_ranking', user_id, user_traits) AS arm
  )
  SELECT p.id, p.title, v.arm
  FROM shop.products p, v, websearch_to_tsquery('english', q) query
  WHERE p.search_vec @@ query
  ORDER BY CASE v.arm
             WHEN 'boosted' THEN ts_rank(p.search_vec, query) * (1 + ln(1 + p.sales_30d))
             ELSE ts_rank(p.search_vec, query)
           END DESC
  LIMIT n
$$;`;

export const Step1: React.FC = () => {
  const f = useCurrentFrame();
  const codeAt = cue('step1', 'In Postgres') - 6;
  const usersAt = cue('step1', 'Two users') - 10;
  const outA = t01(f, codeAt - 6, 10), outB = t01(f, usersAt - 6, 10);
  // the query that ran (term/search.json), re-wrapped to fit the panel
  const short = (it: typeof search[0], id: string) => ({...it, command:
    `SELECT s.title, p.sales_30d, s.arm\nFROM app.users u, shop.search(u.identifier,\n  u.traits, 'wireless headphones', 5) WITH ORDINALITY s\nJOIN shop.products p ON p.id = s.product_id\nWHERE u.identifier = '${id}' ORDER BY s.ordinality;`});
  return (
    <AbsoluteFill>
      <Background />
      <StepBar active={0} />
      {f < codeAt + 4 && (
        <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', paddingTop: 110, paddingBottom: 30, opacity: 1 - outA}}>
          <Browser take="mv" width={1340} from={0} startAt={0.4}
            cams={[{f: 0, scale: 1, x: 0.5, y: 0.5}, {f: Math.round(3.6 * FPS), scale: 1, x: 0.5, y: 0.5},
                   {f: Math.round(5.2 * FPS), scale: 1.55, x: 0.73, y: 0.72}]} />
          <div style={{position: 'absolute', top: 104, left: 0, right: 0, display: 'flex', justifyContent: 'center', ...enter(f, cue('step1', 'split fifty'), 14)}}>
            <Pill color={C.purple2} size={30}>control 50% · boosted 50%</Pill>
          </div>
        </AbsoluteFill>
      )}
      {f >= codeAt - 2 && f < usersAt + 4 && (
        <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', paddingTop: 70, ...enter(f, codeAt, 30), opacity: Math.min(t01(f, codeAt, 12), 1 - outB)}}>
          <Code code={SQL} width={1640} fontSize={25} title="demos/search_ab/schema.sql"
            highlight={[{lines: [3], from: 12, color: 'rgba(139,92,246,.28)'}, {lines: [8, 9, 10, 11], from: cue('step1', 'the same query') - codeAt, color: 'rgba(96,165,250,.14)'}]}
            start={codeAt} />
        </AbsoluteFill>
      )}
      {f >= usersAt - 2 && (
        <AbsoluteFill style={{flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 36, paddingTop: 80, ...enter(f, usersAt, 30)}}>
          {[0, 1].map(i => {
            const id = i === 0 ? 'user-42' : 'user-2024';
            const arm = i === 0 ? 'control' : 'boosted';
            return (
              <div key={id} style={{display: 'flex', flexDirection: 'column', gap: 18, alignItems: 'flex-start'}}>
                <div style={{display: 'flex', gap: 14, alignItems: 'center', ...enter(f, usersAt + i * 18)}}>
                  <span style={{fontFamily: sans, fontSize: 34, fontWeight: 800, color: C.text}}>{id}</span>
                  <Pill color={i === 0 ? C.blue : C.purple2} size={24}>arm: {arm}</Pill>
                </div>
                <Terminal items={[short(search[i], id)]} start={usersAt + i * 18} width={830} height={560} fontSize={19}
                  opts={{cps: 10, lpf: 0.8}} finalPrompt={false}
                  rules={[{match: /\b1[67]\d\d\b/, color: C.green, weight: 800, from: usersAt + 60}, {match: /\| +\d{1,2} \|/, color: C.amber, from: usersAt + 60}]} />
              </div>
            );
          })}
        </AbsoluteFill>
      )}
      {f >= usersAt && (
        <div style={{position: 'absolute', bottom: 120, left: 0, right: 0, textAlign: 'center', ...enter(f, cue('step1', 'One query'), 16)}}>
          <Pill color={C.green} size={28}>same function · same SQL · the flag picked the ranking</Pill>
        </div>
      )}
    </AbsoluteFill>
  );
};
