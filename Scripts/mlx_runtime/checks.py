"""Conservative, local checks of explicitly written expressions, never factual proof.
No eval, SymPy parse_expr, inferred values, model calls or network access.
"""
import ast
import math
import re
from decimal import Decimal
import sympy as sp
import pint
from chempy import Substance

UNITS = pint.UnitRegistry()
NUMBER = r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d{1,2})?'
QUANTITY = re.compile(rf'^({NUMBER})\s+([A-Za-z][A-Za-z0-9/*^ .-]{{0,32}})$')
UNIT_EXPONENT = re.compile(r'(?:\^|\*\*)\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)')


def arithmetic(text):
    if len(text) > 160: raise ValueError('表达式过长')
    tree = ast.parse(text.replace('^', '**'), mode='eval')
    if len(list(ast.walk(tree))) > 64: raise ValueError('表达式过于复杂')
    def visit(node):
        if isinstance(node, ast.Constant) and type(node.value) in (int, float):
            literal = ast.get_source_segment(text.replace('^','**'), node)
            if len(literal) > 24 or abs(node.value) > 1e12: raise ValueError('数值超出核算范围')
            return sp.Rational(literal)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            value = visit(node.operand)
            return -value if isinstance(node.op, ast.USub) else value
        if isinstance(node, ast.BinOp):
            left, right = visit(node.left), visit(node.right)
            if isinstance(node.op, ast.Add): return left + right
            if isinstance(node.op, ast.Sub): return left - right
            if isinstance(node.op, ast.Mult): return left * right
            if isinstance(node.op, ast.Div) and right != 0: return left / right
            if isinstance(node.op, ast.Pow) and right.is_Integer and abs(right) <= 12:
                if left == 0 and right < 0: raise ValueError('零不能取负幂')
                return left ** right
        raise ValueError('只核算已经明确代入数值的算式')
    return visit(tree.body)


def reaction(expression):
    sides = re.split(r'\s*(?:->|→)\s*', expression)
    if len(sides) != 2: raise ValueError('反应方向不明确')
    totals = []
    for side in sides:
        total = {}
        terms = re.split(r'\s+\+\s+', side)
        if len(terms) > 12: raise ValueError('物种过多')
        for term in terms:
            match = re.fullmatch(r'(?:(\d{1,3})\s*)?([A-Z][A-Za-z0-9()\[\]+-]{0,60})',term.strip())
            if not match: raise ValueError('请提供明确化学式；物种之间用空格加号分隔')
            coefficient = int(match[1] or 1)
            if not coefficient: raise ValueError('系数必须为正')
            for element, count in Substance.from_formula(match[2]).composition.items():
                total[element] = total.get(element,0) + coefficient*count
        totals.append({k:v for k,v in total.items() if v})
    return totals[0] == totals[1], '仅核对元素与电荷守恒，不判断反应能否发生或条件是否成立'


def rounding_step(side, language=None):
    """Half a unit in the last digit of the side's number as typed. Zero,
    one-digit integers and integers ending in zero are exact ('1 mile', '1000 m'
    are definitions or ambiguous); other integers get half a unit ('1609 m').
    es/fr normalization drops trailing zeros ('1,50' -> '15e-1'), so the
    written precision comes from the raw literal."""
    side = side.strip()
    if language in ('es', 'fr'):
        from latin_numbers import literals
        raw, start, _, value = next(literals(side, language), (side, 1, 0, '0e0'))
        if start: return 0
        digits = re.sub(r'\D', '', re.split('[eE]', raw)[0])
        coefficient, power = value.split('e')
        last = int(power) - (len(digits) - len(digits.rstrip('0')))
    else:
        raw = coefficient = QUANTITY.fullmatch(side)[1]
        last = Decimal(raw).as_tuple().exponent
    if Decimal(coefficient) == 0: return 0
    if last == 0 and not re.search('[eE]', raw):
        digits = re.sub(r'\D', '', raw).lstrip('0')
        if len(digits) == 1 or digits.endswith('0'): return 0
    return float(Decimal(5).scaleb(last - 1))


def check(expression, language=None):
    expression = expression.strip()
    result = dict(expression=expression, status='unable', scope='无法核算')
    try:
        if '->' in expression or '→' in expression:
            ok, scope = reaction(expression); method='ChemPy'
        else:
            written = expression
            if language in ('es', 'fr'):
                from latin_numbers import normalize_expression
                expression = normalize_expression(expression, language)
            sides = expression.split('=')
            if len(sides)!=2: raise ValueError('需要明确等号两侧的表达式')
            left, right = (s.strip() for s in sides)
            quantities = [QUANTITY.fullmatch(side) for side in (left,right)]
            if all(quantities):
                if any(int(n) > 12 for m in quantities for n in re.findall(r'\d+',m[2])):
                    raise ValueError('单位指数超出核算范围')
                # Locale normalization may turn 20 into 2e1. Check the whole
                # exponent's exact value before Pint constructs the quantities.
                if any(abs(sp.Rational(n)) > 12 for m in quantities for n in UNIT_EXPONENT.findall(m[2])):
                    raise ValueError('单位指数超出核算范围')
                a,b = [UNITS.Quantity(float(m[1]),m[2]) for m in quantities]
                if a.dimensionality != b.dimensionality:
                    ok=False; scope='等号两侧量纲不一致'
                else:
                    value, expected = a.to(b.units).magnitude, b.magnitude
                    # Relative at any magnitude, plus the rounding implied by
                    # the digits written on either side (1 eV = 1.602e-19 J).
                    # No absolute floor, and opposite signs never agree. A
                    # rounding tie (12.5 cm = 0.13 m) must not hinge on float
                    # noise, so allow the same 1e-9 relative noise as above.
                    step_a, step_b = (rounding_step(side, language) for side in written.split('='))
                    slack = max(step_b, abs(UNITS.Quantity(a.magnitude+step_a, a.units).to(b.units).magnitude-value))
                    noise = 1e-9*max(abs(value), abs(expected))
                    ok = math.isclose(value, expected, rel_tol=1e-9, abs_tol=0) or (
                        value*expected > 0 and abs(value-expected) <= slack+noise)
                    scope='仅核对写出的单位换算；不判断量的归属或题设'
                method='Pint'
            else:
                ok = arithmetic(left) == arithmetic(right)
                method='SymPy'; scope='仅核对明确代入的数值等式；未推断变量、对象或条件'
        result.update(status='matches' if ok else 'differs',method=method,scope=scope)
    except Exception as error:
        result['scope']='无法核算：'+str(error)[:160]
    return result


def review_checks(data):
    results=[]
    languages = {q.get('language') for item in data.get('evidence', []) for q in item.get('quotes', [])}
    latin_targets = languages & {'es', 'fr'}
    language = next(iter(latin_targets)) if len(latin_targets) == 1 else None
    for point in data.get('note',{}).get('points',[]):
        text=point.get('text','')
        # Only a whole explicitly delimited equation. Do not fish plausible
        # numbers out of prose or attach them to an inferred object.
        candidates=re.findall(r'`([^`\n]{1,180})`|\$([^$\n]{1,180})\$',text)
        expressions=[a or b for a,b in candidates]
        if not expressions and len(text)<=180 and ('=' in text or '→' in text or '->' in text):
            expressions=[text]
        for expression in expressions[:4]:
            if '=' in expression or '→' in expression or '->' in expression:
                results.append(dict(pointIndex=point['index'],**check(expression, language=language)))
        if len(results)>=32:break
    return dict(version=1, boundary='These checks only concern explicit expressions. They do not verify subject matter, object identity, assumptions, or the truth of source evidence. unable means no conclusion. Never treat matches as proof that the whole note is correct.',results=results[:32])
